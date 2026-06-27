// S_Glass. Full hand-written HDRP refractive glass (ForwardOnly, transparent).
// Color-pyramid refraction with chromatic dispersion, Beer-Lambert absorption over
// analytic convex thickness, GGX direct specular with geometric specular-AA, frost
// via noise-driven roughness blurring both reflection and refraction, and thin-film
// iridescence from a cosine-interference approximation. No diffuse term.

Shader "Renderers/S_Glass"
{
    Properties
    {
        _Tint ("Tint", Color) = (1, 1, 1, 0.5)
        _IOR  ("IOR", Range(1.0, 2.5)) = 1.5
        _FrensnelAdjust ("Frensnel Adjust Multiplier", Float) = 1.0
        _lod ("LOD Reflection MAP", Int) = 0
        _RefractStrength ("Refraction Strength", Range(0.0, 10.0)) = 1.0
        _MaxOffset ("Max Refract Offset", Range(0.0, 0.2)) = 0.05

        _Density   ("Absorption Density", Range(0.0, 10.0)) = 1.0
        _Thickness ("Thickness Scale", Range(0.0, 5.0)) = 1.0

        _Roughness ("Roughness", Range(0.0, 1.0)) = 0.05
        _Dispersion ("Dispersion", Range(0.0, 0.3)) = 0.03

        _FilmThickness ("Thin-Film Thickness (nm)", Range(100.0, 1000.0)) = 380.0
        _FilmIOR       ("Thin-Film IOR", Range(1.0, 3.0)) = 1.35
        _Iridescence   ("Iridescence Strength", Range(0.0, 1.0)) = 0.0

        _RoughnessNoise ("Roughness Noise", 2D) = "white" {}
        _NoiseTiling    ("Noise Tiling", Float) = 20.0
        _NoiseStrength  ("Noise Strength", Range(0.0, 1.0)) = 0.5
        _FrostBlur      ("Frost Blur Mips", Range(0.0, 8.0)) = 6.0

        _SpecAA ("Specular AA Strength", Range(0.0, 4.0)) = 2.0
    }

    SubShader
    {
        Tags{ "RenderPipeline" = "HDRenderPipeline" "Queue" = "Transparent" }

        Pass
        {
            Name "ForwardOnly"
            Tags { "LightMode" = "ForwardOnly" }
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            ZTest LEqual
            Cull Back

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex Vert
            #pragma fragment Frag
            #pragma multi_compile_instancing

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"
            #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariablesFunctions.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/SpaceTransforms.hlsl"
            #include "Packages/com.unity.render-pipelines.high-definition/Runtime/RenderPipeline/RenderPass/CustomPass/CustomPassCommon.hlsl"

            TEXTURE2D(_RoughnessNoise);
            SAMPLER(sampler_linear_repeat);
            SAMPLER(sampler_linear_clamp);

            CBUFFER_START(UnityPerMaterial)
                float4 _Tint;
                float  _IOR;
                float  _lod;
                float  _FrensnelAdjust;
                float  _RefractStrength;
                float  _MaxOffset;
                float  _Density;
                float  _Thickness;
                float  _Roughness;
                float  _Dispersion;
                float  _FilmThickness;
                float  _FilmIOR;
                float  _Iridescence;
                float  _NoiseTiling;
                float  _NoiseStrength;
                float  _FrostBlur;
                float  _SpecAA;
            CBUFFER_END

            struct GlassAttributes
            {
                float3 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float2 uv         : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct GlassVaryings
            {
                float4 positionCS : SV_POSITION;
                float3 positionWS : TEXCOORD1;
                float3 normalWS   : NORMAL;
                float2 uv         : TEXCOORD0;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            GlassVaryings Vert(GlassAttributes input)
            {
                GlassVaryings output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                output.positionWS = TransformObjectToWorld(input.positionOS);
                output.positionCS = TransformWorldToHClip(output.positionWS);
                output.normalWS   = TransformObjectToWorldNormal(input.normalOS);
                output.uv         = input.uv;
                return output;
            }

            float4 Frag(GlassVaryings input, float4 screenPos : SV_Position) : SV_Target
            {
                float3 V   = normalize(-input.positionWS);
                float3 N   = normalize(input.normalWS);
                float  NoV = saturate(dot(N, V));
                float3 R   = reflect(-V, N);
                float2 screenUV = screenPos.xy * _ScreenSize.zw;

                //Analytic convex thickness (exact for a sphere: 2r·NoV) 
                float thickness = NoV * _Thickness;

                //Noise-driven roughness (frost) 
                float noise     = SAMPLE_TEXTURE2D(_RoughnessNoise, sampler_linear_repeat, input.uv * _NoiseTiling).r;
                float roughness = saturate(_Roughness + noise * _NoiseStrength);
                float blurMip   = roughness * _FrostBlur;

                //Fresnel 
                float f0s     = (_IOR - 1.0) / (_IOR + 1.0);
                float F0      = f0s * f0s;
                float fresnel = saturate((F0 + (1.0 - F0) * pow(1.0 - NoV, 5.0)) * _FrensnelAdjust);

                //Environment Reflection (blurred by frost) 
                float4 envSample = SAMPLE_TEXTURECUBE_ARRAY_LOD(_SkyTexture, sampler_linear_clamp, R, 0.0, _lod + blurMip);
                float3 envColor  = envSample.rgb * GetCurrentExposureMultiplier();

                // Refraction (IOR-driven, chromatic dispersion, frost blur) 
                float iorR = _IOR - _Dispersion;
                float iorG = _IOR;
                float iorB = _IOR + _Dispersion;

                float surfaceEye  = LinearEyeDepth(screenPos.z, _ZBufferParams);
                float2 e          = min(screenUV, 1.0 - screenUV);
                float  edgeFade   = saturate(min(e.x, e.y) / 0.05);
                float  offsetScale = min(
                    _RefractStrength * thickness * edgeFade / max(surfaceEye, 1e-3),
                    _MaxOffset);

                float2 offR = refract(-V, N, 1.0 / iorR).xy * offsetScale;
                float2 offG = refract(-V, N, 1.0 / iorG).xy * offsetScale;
                float2 offB = refract(-V, N, 1.0 / iorB).xy * offsetScale;

                float3 refractColor;
                refractColor.r = SAMPLE_TEXTURE2D_X_LOD(_ColorPyramidTexture, sampler_linear_clamp, screenUV + offR, blurMip).r;
                refractColor.g = SAMPLE_TEXTURE2D_X_LOD(_ColorPyramidTexture, sampler_linear_clamp, screenUV + offG, blurMip).g;
                refractColor.b = SAMPLE_TEXTURE2D_X_LOD(_ColorPyramidTexture, sampler_linear_clamp, screenUV + offB, blurMip).b;

                // Beer-Lambert Absorption (transmission path only) 
                float3 absorption   = (1.0 - _Tint.rgb) * _Density;
                float3 transmission = exp(-absorption * thickness);
                refractColor *= transmission;

                // Direct Specular (GGX, no diffuse)
                float a  = roughness * roughness;
                float a2 = a * a;

                // Geometric specular AA: widen the lobe where N aliases per-pixel (distance/rim).
                // The GGX D term can't be mip-blurred, so soften the lobe itself based on how fast
                // the normal changes across the pixel — kills firefly highlights at distance.
                float3 du       = ddx(N);
                float3 dv       = ddy(N);
                float  variance = 0.25 * (dot(du, du) + dot(dv, dv));
                a2 = saturate(a2 + min(_SpecAA * variance, 0.18));
                a  = sqrt(a2);

                float kg = ((a + 1.0) * (a + 1.0)) / 8.0;
                float Gv = NoV / (NoV * (1.0 - kg) + kg);

                float3 directSpec = float3(0.0, 0.0, 0.0);
                for (int i = 0; i < _DirectionalLightCount; ++i)
                {
                    DirectionalLightData lightData = _DirectionalLightDatas[i];
                    float3 L = -lightData.forward.xyz;

                    float3 H   = normalize(L + V);
                    float  NoL = saturate(dot(N, L));
                    float  NoH = saturate(dot(N, H));
                    float  VoH = saturate(dot(V, H));

                    float  d  = (NoH * NoH) * (a2 - 1.0) + 1.0;
                    float  D  = a2 / (PI * d * d + 1e-4);
                    float  Fs = F0 + (1.0 - F0) * pow(1.0 - VoH, 5.0);
                    float  Gl = NoL / (NoL * (1.0 - kg) + kg);
                    float  G  = Gl * Gv;

                    float  spec = (D * Fs * G) / max(4.0 * NoL * NoV, 1e-4);
                    directSpec += spec * lightData.color * NoL;
                }
                directSpec *= GetCurrentExposureMultiplier();

                // Thin-Film Iridescence (cosine-interference approximation) 
                float  sinT2    = (1.0 - NoV * NoV) / (_FilmIOR * _FilmIOR);
                float  cosT     = sqrt(saturate(1.0 - sinT2));
                float  opd      = 2.0 * _FilmIOR * _FilmThickness * cosT;
                float3 phase    = (2.0 * PI) * opd / float3(680.0, 550.0, 440.0);
                float3 iri      = 0.5 + 0.5 * cos(phase);
                float3 filmTint = lerp(float3(1.0, 1.0, 1.0), iri, _Iridescence);

                envColor   *= filmTint;
                directSpec *= filmTint;

                //Composite 
                float3 color = lerp(refractColor, envColor, fresnel) + directSpec;

                float  specLum = dot(directSpec, float3(0.2126, 0.7152, 0.0722));
                float  alpha   = saturate(_Tint.a + fresnel + specLum);

                return float4(color, alpha);
            }
            ENDHLSL
        }
    }
}