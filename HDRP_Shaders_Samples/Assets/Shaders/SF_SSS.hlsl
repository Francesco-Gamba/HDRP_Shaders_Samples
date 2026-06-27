// SF_SSS. Shader Graph Custom Function for fast subsurface scattering.
// Front scattering via wrapped lighting around the terminator, plus view-dependent
// back scattering (per-channel RGB falloff) for light transmitted through thin areas.
// Thickness-modulated, with HDRP exposure compensation. A cheap approximation,
// not a physically-based diffusion profile.

#include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"

void SF_SSS_float(
    float  SF_thickness,     
    float3 SF_worldNormal,
    float3 SF_lightDir,      
    float3 SF_viewDir,       
    float3 SF_sssColor,      
    float3 SF_lightColor,    
    float  SF_wrapAmount,    
    float3 SF_sssPower,      
    float  SF_sssScale,      
    float  SF_distortion,
    float  SF_intensity,
    out float3 SF_sssOutput  
)
{
    float3 N = normalize(SF_worldNormal);
    float3 L = normalize(SF_lightDir);
    float3 V = normalize(SF_viewDir);

    // front scattering - wrap lighting around terminator
    float NdotL = dot(N, L);
    float wrapScatter = saturate((NdotL + SF_wrapAmount) / (1.0 + SF_wrapAmount));
    float shadowMask = saturate(NdotL + 0.1);
    float3 frontScattering = wrapScatter * SF_sssColor * shadowMask;

    // back scattering - transmitted light through thin areas
    float3 distortedLight = normalize(L + (N * SF_distortion));
    float viewDotLight = saturate(dot(V, -distortedLight));

    float3 forwardScatter;
    forwardScatter.r = pow(viewDotLight, SF_sssPower.r);
    forwardScatter.g = pow(viewDotLight, SF_sssPower.g);
    forwardScatter.b = pow(viewDotLight, SF_sssPower.b);

    forwardScatter *= SF_sssScale * (1.0 - SF_thickness);
    float backMask = saturate(-NdotL);
    float3 backScattering = forwardScatter * SF_sssColor * backMask;

    //counteract HDRP exposure
    float exposure = GetCurrentExposureMultiplier();
    SF_sssOutput = (frontScattering + backScattering) * SF_lightColor * SF_intensity / exposure;
}