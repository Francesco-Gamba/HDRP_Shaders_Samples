// S_GlassCheap - Minimal HDRP transparent glass. Fresnel-weighted environment
// reflection sampled from the sky cubemap with smoothness-driven mip blur.
// No refraction, no absorption, a cheap, performant glass for distant or
// secondary surfaces where the full S_Glass cost isn't justified.

Shader "Renderers/S_GlassCheap"
{
    Properties
    {
        _Tint               ("Tint (a = base opacity)", Color) = (1, 1, 1, 0.25)
        _Smoothness         ("Smoothness", Range(0.0, 1.0)) = 0.95
        _FresnelPower       ("Fresnel Power", Range(1.0, 8.0)) = 5.0
        _ReflectionStrength ("Reflection Strength", Range(0.0, 2.0)) = 1.0
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

            SAMPLER(sampler_linear_clamp);

            CBUFFER_START(UnityPerMaterial)
                float4 _Tint;
                float  _Smoothness;
                float  _FresnelPower;
                float  _ReflectionStrength;
            CBUFFER_END

            struct GlassAttributes
            {
                float3 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct GlassVaryings
            {
                float4 positionCS : SV_POSITION;
                float3 positionWS : TEXCOORD0;
                float3 normalWS   : TEXCOORD1;
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
                return output;
            }

            float4 Frag(GlassVaryings input) : SV_Target
            {
                float3 V   = normalize(-input.positionWS);
                float3 N   = normalize(input.normalWS);
                float  NoV = saturate(dot(N, V));
                float3 R   = reflect(-V, N);

                float fresnel = pow(1.0 - NoV, _FresnelPower);

                float  mip = (1.0 - _Smoothness) * 6.0;
                float3 env = SAMPLE_TEXTURECUBE_ARRAY_LOD(_SkyTexture, sampler_linear_clamp, R, 0.0, mip).rgb;
                env *= GetCurrentExposureMultiplier();

                float3 color = env * _Tint.rgb * _ReflectionStrength * fresnel;
                float  alpha = saturate(_Tint.a + fresnel);

                return float4(color, alpha);
            }
            ENDHLSL
        }
    }
}