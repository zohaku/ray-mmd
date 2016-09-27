#include "../ray.conf"
#include "../shader/math.fx"
#include "../shader/common.fx"
#include "../shader/shadowcommon.fx"

#define CalcLight(casterDepth, receiverDepth, rate)	(1.0 - saturate(max(receiverDepth - casterDepth, 0) * rate))
float3  LightDirection : DIRECTION < string Object = "Light"; >;
static float4x4 matLightView = CreateLightViewMatrix(normalize(LightDirection));
static float4x4 matLightProjectionToCameraView = mul(matViewInverse, matLightView);
static float4x4 matLightWorldViewProject = mul(matLightView, matLightProject);
static float4x4 lightParam = CreateLightProjParameters(matLightProjectionToCameraView);

texture DiffuseMap: MATERIALTEXTURE;
sampler DiffuseMapSamp = sampler_state {
	texture = <DiffuseMap>;
	MinFilter = POINT;	MagFilter = POINT;	MipFilter = POINT;
	ADDRESSU  = WRAP;	ADDRESSV  = WRAP;
};

shared texture PSSM : OFFSCREENRENDERTARGET;
sampler PSSMsamp = sampler_state {
	texture = <PSSM>;
	MinFilter = LINEAR;	MagFilter = LINEAR;	MipFilter = POINT;
	AddressU  = CLAMP;	AddressV = CLAMP;
};

struct DrawObject_OUTPUT
{
	float4 Pos	  : POSITION;
	float4 Tex	  : TEXCOORD0;
	float3 Normal	: TEXCOORD1;

	float4 LightPPos01	: TEXCOORD2;
	float4 LightPPos23	: TEXCOORD3;

	float4 PPos		: TEXCOORD4;
};

inline float CalcEdgeFalloff(float2 texCoord)
{
	const float m = (SHADOW_MAP_SIZE * 0.5 / WARP_RANGE);
	const float a = (SHADOW_MAP_OFFSET * 1.0 / WARP_RANGE);
	float2 falloff = abs(texCoord) * (-m * 4.0) + (m - a);
	return saturate(min(falloff.x, falloff.y));
}

inline float4 CalcCascadePPos(float2 uv, float2 offset, float index)
{
	return float4(uv + ((0.5 + offset) * 0.5 + (0.5 / SHADOW_MAP_SIZE)), index, CalcEdgeFalloff(uv));
}

void ShadowlessObjectVS(
	in float4 Position : POSITION, 
	in float2 Texcoord : TEXCOORD0,
	out float3 oTexcoord : TEXCOORD0,
	out float4 oPosition : POSITION)
{
	oPosition = mul(Position, matViewProject);
	oTexcoord.xy = Texcoord.xy;
	oTexcoord.z = oPosition.z;
}

float4 ShadowlessObjectPS(float3 coord : TEXCOORD0, uniform bool useTexture) : COLOR
{
	clip(!opadd - 0.001f);
	float alpha = MaterialDiffuse.a;
	if (useTexture) alpha *= tex2D(DiffuseMapSamp, coord).a;
	clip(alpha - RecieverAlphaThreshold);
	return float4(1, 0.0, coord.z, alpha);
}

DrawObject_OUTPUT DrawObject_VS(float4 Pos : POSITION, float3 Normal : NORMAL, float2 Tex : TEXCOORD0, uniform bool useTexture)
{
	DrawObject_OUTPUT Out = (DrawObject_OUTPUT)0;

	Out.PPos = Out.Pos = mul(Pos, matViewProject);
	Out.Normal = Normal;

	float4 PPos = mul(Pos, matLightWorldViewProject);
	PPos /= PPos.w;

	const float2 scale = float2(0.25, -0.25);
	Out.LightPPos01.xy = (PPos.xy * lightParam[0].xy + lightParam[0].zw);
	Out.LightPPos01.zw = (PPos.xy * lightParam[1].xy + lightParam[1].zw);
	Out.LightPPos23.xy = (PPos.xy * lightParam[2].xy + lightParam[2].zw);
	Out.LightPPos23.zw = (PPos.xy * lightParam[3].xy + lightParam[3].zw);
	Out.LightPPos01 *= scale.xyxy;
	Out.LightPPos23 *= scale.xyxy;

	Out.Tex.xy = Tex.xy;
	Out.Tex.z = Out.Pos.z;
	Out.Tex.w = PPos.z;

	return Out;
}

float4 DrawObject_PS(DrawObject_OUTPUT IN, uniform bool useTexture) : COLOR
{
	float alpha = MaterialDiffuse.a;
	if ( useTexture ) alpha *= tex2D(DiffuseMapSamp, IN.Tex.xy).a;
	clip(alpha - RecieverAlphaThreshold);

	float3 N = normalize(IN.Normal);
	float dotNL = dot(N, -LightDirection);
	
	float distanceFromCamera = IN.PPos.z;

	float4 lightPPos0 = CalcCascadePPos(IN.LightPPos01.xy, float2(0, 0), 0);
	float4 lightPPos1 = CalcCascadePPos(IN.LightPPos01.zw, float2(1, 0), 1);
	float4 lightPPos2 = CalcCascadePPos(IN.LightPPos23.xy, float2(0, 1), 2);
	float4 lightPPos3 = CalcCascadePPos(IN.LightPPos23.zw, float2(1, 1), 3);

	float4 texCoord0 = lightPPos3;
	float4 texCoord1 = 0;
	if (lightPPos2.w > 0.0) { texCoord1 = texCoord0; texCoord0 = lightPPos2; }
	if (lightPPos1.w > 0.0) { texCoord1 = texCoord0; texCoord0 = lightPPos1; }
	if (lightPPos0.w > 0.0) { texCoord1 = texCoord0; texCoord0 = lightPPos0; }

	float casterDepth0 = tex2D(PSSMsamp, texCoord0.xy).x;
	float casterDepth1 = tex2D(PSSMsamp, texCoord1.xy).x;
	float casterDepth = lerp(lerp(1, casterDepth1, texCoord1.w), casterDepth0, texCoord0.w);
	float receiverDepth = IN.Tex.w;

	float bias = IN.PPos.z * (1.0 / LightZMax);
	float depthSlope = min(abs( ddx( receiverDepth ) ) + abs( ddy( receiverDepth ) ), 0.1);
	float lightSlpoe = min(1.0 / (abs(dotNL) + 1.0e-4), 8.0) * (1.0 / LightZMax);
	bias = (bias + depthSlope + lightSlpoe) * BIAS_SCALE;
	receiverDepth -= bias;

	float sdrate = 30000.0 / 4.0 - 0.05;
	float light = CalcLight(casterDepth.x, receiverDepth, sdrate);
	float dist = receiverDepth - casterDepth.x;
	float thick = max(dist * LightZMax, 0);

	float light_sub = 0;
	const float s = 1.0 / SHADOW_MAP_SIZE;
	int2 iuv = (IN.PPos.xy / IN.PPos.w + 1) * 0.5 * ViewportSize;
	float jitter = GetJitterOffset(iuv);
	texCoord0.xy += (jitter * 2.0 - 1.0) * 0.5 * s;

	#if SHADOW_QUALITY >= 2
	const float scale = 1.0 / (5 + 4 * 0.75);
	light_sub += CalcLight(tex2D(PSSMsamp, texCoord0.xy + float2( s, s)).x, receiverDepth, sdrate);
	light_sub += CalcLight(tex2D(PSSMsamp, texCoord0.xy + float2(-s, s)).x, receiverDepth, sdrate);
	light_sub += CalcLight(tex2D(PSSMsamp, texCoord0.xy + float2( s,-s)).x, receiverDepth, sdrate);
	light_sub += CalcLight(tex2D(PSSMsamp, texCoord0.xy + float2(-s,-s)).x, receiverDepth, sdrate);
	light_sub *= 0.75;
	#else
	const float scale = 1.0 / 5;
	#endif
	light_sub += CalcLight(tex2D(PSSMsamp, texCoord0.xy + float2( s, 0)).x, receiverDepth, sdrate);
	light_sub += CalcLight(tex2D(PSSMsamp, texCoord0.xy + float2(-s, 0)).x, receiverDepth, sdrate);
	light_sub += CalcLight(tex2D(PSSMsamp, texCoord0.xy + float2( 0, s)).x, receiverDepth, sdrate);
	light_sub += CalcLight(tex2D(PSSMsamp, texCoord0.xy + float2( 0,-s)).x, receiverDepth, sdrate);

	float lightPCF = (light + light_sub) * scale;
	light = lerp(light, lightPCF, texCoord0.w);
	light = light * light;
	light = min(light, (dotNL > 0.0));
	
	return float4(light, distanceFromCamera, 0, 1);
}

#define OBJECT_NO_SHADOW_TEC(name, mmdpass, tex) \
	technique name < string MMDPass = mmdpass; bool UseTexture = tex; \
	> { \
		pass DrawObject { \
			AlphaTestEnable = FALSE; AlphaBlendEnable = FALSE; \
			VertexShader = compile vs_3_0 ShadowlessObjectVS(); \
			PixelShader  = compile ps_3_0 ShadowlessObjectPS(tex); \
		} \
	}

#define OBJECT_TEC(name, mmdpass, tex) \
	technique name < string MMDPass = mmdpass; bool UseTexture = tex; \
	> { \
		pass DrawObject { \
			AlphaTestEnable = FALSE; AlphaBlendEnable = FALSE; \
			VertexShader = compile vs_3_0 DrawObject_VS(tex); \
			PixelShader  = compile ps_3_0 DrawObject_PS(tex); \
		} \
	}

OBJECT_NO_SHADOW_TEC(MainTec2, "object", false)
OBJECT_NO_SHADOW_TEC(MainTec3, "object", true)

OBJECT_TEC(MainTecBS2, "object_ss", false)
OBJECT_TEC(MainTecBS3, "object_ss", true)

technique EdgeTec < string MMDPass = "edge"; > {}
technique ShadowTec < string MMDPass = "shadow"; > {}
technique ZplotTec < string MMDPass = "zplot"; > {}