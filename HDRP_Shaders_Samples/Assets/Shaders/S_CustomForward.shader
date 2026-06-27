// S_CustomForward. Hand-written HDRP forward PBR shader (ForwardOnly + ShadowCaster).
// Cook-Torrance GGX direct lighting with Smith-Schlick geometry, Karis analytic DFG
// for indirect specular, SH L2 ambient diffuse, and main-directional shadow sampling
// pulled out of the light loop to keep the cascade selector in a static context.
// Albedo / Roughness / Metalness / Normal inputs. No Shader Graph, no Lit.hlsl.

Shader "Renderers/S_CustomForward"
{
    Properties
    {
        _Albedo("Albedo", 2D) = "white" {}
        _Roughness("Roughness", 2D) = "white" {}
        _Metalness("Metalness", 2D) = "white" {}
        _Normal ("Normal", 2D) = "bump" {}
        _lod ("LOD Reflection MAP", Int) = 0
    }

    SubShader
    {
        Tags{ "RenderPipeline" = "HDRenderPipeline" }

        Pass
        {
            Name "ForwardOnly"
            Tags { "LightMode" = "ForwardOnly" }
            Blend Off
            ZWrite On
            ZTest LEqual
            Cull Back

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex Vert
            #pragma fragment Frag
            #pragma multi_compile_instancing
            #pragma multi_compile_fragment PUNCTUAL_SHADOW_LOW PUNCTUAL_SHADOW_MEDIUM PUNCTUAL_SHADOW_HIGH
            #pragma multi_compile_fragment DIRECTIONAL_SHADOW_LOW DIRECTIONAL_SHADOW_MEDIUM DIRECTIONAL_SHADOW_HIGH
            #pragma multi_compile_fragment AREA_SHADOW_MEDIUM AREA_SHADOW_HIGH

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/EntityLighting.hlsl"
            #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"
            #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariablesFunctions.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/SpaceTransforms.hlsl"
            #include "Packages/com.unity.render-pipelines.high-definition/Runtime/RenderPipeline/RenderPass/CustomPass/CustomPassCommon.hlsl"
            #include "Packages/com.unity.render-pipelines.high-definition/Runtime/Lighting/LightLoop/HDShadow.hlsl"   // + SHADOW : InitShadowContext + GetDirectionalShadowAttenuation

            // Material textures
            TEXTURE2D(_Albedo);
            TEXTURE2D(_Roughness);
            TEXTURE2D(_Metalness);
            TEXTURE2D(_Normal);
            SAMPLER(sampler_linear_repeat);

            // HDRP global textures
            TEXTURECUBE_ARRAY(_EnvCubemapTextures);
            SAMPLER(sampler_EnvCubemapTextures);
            TEXTURE2D(_PreIntegratedFGD_GGXDisneyDiffuse);
            SAMPLER(sampler_linear_clamp);

            CBUFFER_START(UnityPerMaterial)
                float4 _Albedo_ST;
                float4 _Roughness_ST;
                float4 _Metalness_ST;
                float4 _Normal_ST;
                float _lod;
            CBUFFER_END

            struct MyAttributes
            {
                float3 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float2 uv         : TEXCOORD0;
                float4 tangentOS  : TANGENT;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct MyVaryings
            {
                float4 positionCS  : SV_POSITION;
                float3 positionWS  : TEXCOORD1;
                float3 normalWS    : NORMAL;
                float2 uv          : TEXCOORD0;
                float3 tangentWS   : TEXCOORD3;
                float3 bitangentWS : TEXCOORD4;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            float3 DecodeHDRI(float4 color) { return color.rgb * color.a; }

            float3 UnpackNormalToWorld(float4 rawSample, float3 normalWS, float3 tangentWS, float3 bitangentWS)
            {
                float3 tangentNormal = UnpackNormal(rawSample);
                float3x3 tbn = float3x3(normalize(tangentWS), normalize(bitangentWS), normalize(normalWS));
                return normalize(mul(tangentNormal, tbn));
            }

            MyVaryings Vert(MyAttributes input)
            {
                MyVaryings output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                output.positionWS  = TransformObjectToWorld(input.positionOS);
                output.positionCS  = TransformWorldToHClip(output.positionWS);
                output.normalWS    = TransformObjectToWorldNormal(input.normalOS);
                output.uv          = input.uv;
                output.tangentWS   = TransformObjectToWorldDir(input.tangentOS.xyz);
                output.bitangentWS = cross(output.normalWS, output.tangentWS) * input.tangentOS.w;
                return output;
            }

            float4 Frag(MyVaryings input, float4 screenPos : SV_Position) : SV_Target
            {
                float2 uv = input.uv;

                //map Sampling
                float3 albedoColor  = SAMPLE_TEXTURE2D(_Albedo, sampler_linear_repeat, uv).rgb;
                float  roughnessVal = SAMPLE_TEXTURE2D(_Roughness, sampler_linear_repeat, uv).r;
                float  metalnessVal = SAMPLE_TEXTURE2D(_Metalness, sampler_linear_repeat, uv).r;
                float4 rawNormal    = SAMPLE_TEXTURE2D(_Normal, sampler_linear_repeat, uv);

                //Surface Vectors
                float3 V   = normalize(-input.positionWS);
                float3 N   = UnpackNormalToWorld(rawNormal, input.normalWS, input.tangentWS, input.bitangentWS);
                float3 R   = reflect(-V, N);
                float  NoV = saturate(dot(N, V));

                //Microfacet Setup
                float  alpha  = roughnessVal * roughnessVal;
                float  alpha2 = alpha * alpha;
                float3 F0 = lerp(float3(0.04, 0.04, 0.04), albedoColor, metalnessVal);

                float k  = ((alpha + 1.0) * (alpha + 1.0)) / 8.0;
                float Gv = NoV / (NoV * (1.0 - k) + k);

                // Analytic DFG (Karis 2014)
                float4 c0   = float4(-1.0, -0.0275, -0.572,  0.022);
                float4 c1   = float4( 1.0,  0.0425,  1.040, -0.040);
                float4 r    = roughnessVal * c0 + c1;
                float  a004 = min(r.x * r.x, exp2(-9.28 * NoV)) * r.x + r.y;
                float2 dfg  = float2(-1.04, 1.04) * a004 + r.zw;

                // Indirect Fresnel and diffuse weight
                float3 F_Indirect  = F0 + (max(1.0 - roughnessVal, F0) - F0) * pow(1.0 - NoV, 5.0);
                float3 kD_Indirect = (1.0 - F_Indirect) * (1.0 - metalnessVal);

                // Main Directional Shadow
                // + SHADOW : HDRP allows only ONE shadow-casting directional light (the main light, index 0).
                // Sampled ONCE here, outside the light loop, so the cascade-selector's forced [unroll]
                // resolves in a static context and isn't replicated per light iteration.
                HDShadowContext shadowContext = InitShadowContext();
                float mainShadow = 1.0;
                if (_DirectionalLightCount > 0)
                {
                    DirectionalLightData mainLight = _DirectionalLightDatas[0];
                    if (mainLight.shadowIndex >= 0)
                    {
                        float3 Lmain = -mainLight.forward.xyz;
                        mainShadow = GetDirectionalShadowAttenuation(
                            shadowContext, screenPos.xy, input.positionWS, N, mainLight.shadowIndex, Lmain);
                        mainShadow = lerp(1.0, mainShadow, mainLight.shadowDimmer);
                    }
                }

                //Direct Lighting Loop
                float3 directLighting = float3(0.0, 0.0, 0.0);
                for (int i = 0; i < _DirectionalLightCount; ++i)
                {
                    DirectionalLightData lightData = _DirectionalLightDatas[i];
                    float3 L = -lightData.forward.xyz;
                    float3 lightColor = lightData.color;

                    float3 H   = normalize(L + V);
                    float  NoL = saturate(dot(N, L));
                    float  NoH = saturate(dot(N, H));
                    float  VoH = saturate(dot(V, H));

                    // GGX NDF
                    float denomPart = (NoH * NoH) * (alpha2 - 1.0) + 1.0;
                    float D = alpha2 / (PI * denomPart * denomPart + 0.0001);

                    // Schlick Fresnel
                    float3 F = F0 + (1.0 - F0) * pow(1.0 - VoH, 5.0);

                    // Smith-GGX geometry
                    float Gl = NoL / (NoL * (1.0 - k) + k);
                    float G  = Gl * Gv;

                    float3 kD_Direct = (1.0 - F) * (1.0 - metalnessVal);
                    float3 diffuseReflection  = kD_Direct * albedoColor / PI;
                    float3 specularReflection = (D * F * G) / max(4.0 * NoL * NoV, 0.0001);

                    float shadowAtten = (i == 0) ? mainShadow : 1.0; 
                    directLighting += (diffuseReflection + specularReflection) * lightColor * NoL * shadowAtten;
                }

                // Indirect Diffuse (SH L2)
                float4 shVectorA = float4(N, 1.0);
                float4 shVectorB = N.xyzz * N.yzzx;
                float  shVectorC = N.x * N.x - N.y * N.y;

                float3 ambientDiffuse;
                ambientDiffuse.r = dot(unity_SHAr, shVectorA) + dot(unity_SHBr, shVectorB) + unity_SHC.r * shVectorC;
                ambientDiffuse.g = dot(unity_SHAg, shVectorA) + dot(unity_SHBg, shVectorB) + unity_SHC.g * shVectorC;
                ambientDiffuse.b = dot(unity_SHAb, shVectorA) + dot(unity_SHBb, shVectorB) + unity_SHC.b * shVectorC;
                ambientDiffuse   = max(float3(0.0, 0.0, 0.0), ambientDiffuse);

                // Metal ambient floor — prevents pure black in shadowed areas, tinted by F0
                float3 metalAmbientFloor = ambientDiffuse * F0 * 0.04 * metalnessVal;
                float3 indirectDiffuse   = ambientDiffuse * kD_Indirect * albedoColor + metalAmbientFloor;

                // Indirect Specular 
                float  horizon     = min(1.0 + dot(R, N), 1.0);
                float  horizonFade = horizon;

                float4 specularSample = SAMPLE_TEXTURECUBE_ARRAY_LOD(_SkyTexture, sampler_linear_clamp, R, 0.0, _lod);
                float3 indirectSpecular = specularSample.rgb * (F0 * saturate(dfg.x * 2.0) + dfg.y * metalnessVal) * horizonFade;

                // Final Composite 
                float3 finalColor = (directLighting + indirectDiffuse + indirectSpecular) * GetCurrentExposureMultiplier();

                return float4(finalColor, 1.0);
            }
            ENDHLSL
        }
        
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }

            ZWrite On
            ZTest LEqual
            ColorMask 0
            Cull Back

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex ShadowVert
            #pragma fragment ShadowFrag
            #pragma multi_compile_instancing

            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/SpaceTransforms.hlsl"

            CBUFFER_START(UnityPerMaterial)
                float4 _Albedo_ST;
                float4 _Roughness_ST;
                float4 _Metalness_ST;
                float4 _Normal_ST;
                float _lod;
            CBUFFER_END

            struct ShadowAttributes
            {
                float3 positionOS : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct ShadowVaryings
            {
                float4 positionCS : SV_POSITION;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            ShadowVaryings ShadowVert(ShadowAttributes input)
            {
                ShadowVaryings output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

                float3 positionWS = TransformObjectToWorld(input.positionOS);
                output.positionCS = TransformWorldToHClip(positionWS);
                return output;
            }

            float4 ShadowFrag(ShadowVaryings input) : SV_Target { return 0; }
            ENDHLSL
        }
    }
}