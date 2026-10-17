// Under the water: everything in view (hulls, the sky past the surface's edge) fades into the
// water's own colour along its sight line, the red first. Put on a cube under the ocean (large
// bounds; see Ocean.prefab): the vertex shader re-centres it on the camera, and it draws nothing
// while the camera is above the surface. The surface from below is Ocean.shader's (stencil 128).
// Needs the camera depth texture (in VRChat: a realtime directional light with shadows).
// Waves and water colour are copied from the ocean material by OceanFFT (underwaterMaterial).
Shader "VRCOcean/Underwater"
{
    Properties
    {
        [HideInInspector] _Chlorophyll ("", Float) = 0.2
        [HideInInspector] _DispScale ("", Float) = 1
        [HideInInspector] _UnderwaterExposure ("", Float) = 6
        [HideInInspector] _DispTex0 ("", 2D) = "black" {}
        [HideInInspector] _DispTex1 ("", 2D) = "black" {}
        [HideInInspector] _DispTex2 ("", 2D) = "black" {}
        [HideInInspector] _DispTex3 ("", 2D) = "black" {}
    }
    CGINCLUDE
    #include "UnityCG.cginc"
    #include "Lighting.cginc"

    sampler2D _DispTex0, _DispTex1, _DispTex2, _DispTex3;
    float4 _Cascade0, _Cascade1, _Cascade2, _Cascade3;
    float4 _Flow0, _Flow1, _Flow2, _Flow3;
    float _DispScale, _Chlorophyll, _UnderwaterExposure;
    #include "Underwater.cginc"
    UNITY_DECLARE_DEPTH_TEXTURE(_CameraDepthTexture);

    struct appdata { float4 vertex : POSITION; UNITY_VERTEX_INPUT_INSTANCE_ID };
    struct v2f
    {
        float4 pos : SV_POSITION;
        float3 dir : TEXCOORD0;
        float4 screenPos : TEXCOORD1;
        float depth : TEXCOORD2;
        UNITY_VERTEX_OUTPUT_STEREO
    };

    v2f vert(appdata v)
    {
        v2f o;
        UNITY_SETUP_INSTANCE_ID(v);
        UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
        // Unit cube around the camera, just past the near plane, from the view rotation only
        // (as VRCClouds' CloudVolume: camera position + 1 m in world space shimmers at a few km).
        o.dir = v.vertex.xyz;
        float3 viewPos = mul((float3x3)UNITY_MATRIX_V, v.vertex.xyz * (_ProjectionParams.y * 4));
        o.depth = CameraDepth(unity_ObjectToWorld._m13);
        o.pos = o.depth > 0.0 ? mul(UNITY_MATRIX_P, float4(viewPos, 1)) : 0.0;   // above: nothing drawn
        o.screenPos = ComputeScreenPos(o.pos);
        return o;
    }

    // Transmittance and in-scattered radiance along this pixel's sight line, with the eye's adaptation.
    void Fog(v2f i, out float3 t, out float3 inscatter)
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
        float raw = SAMPLE_DEPTH_TEXTURE_PROJ(_CameraDepthTexture, UNITY_PROJ_COORD(i.screenPos));
        // Sky pixels sit at the far plane: kilometres of water, fully faded.
        float dist = LinearEyeDepth(raw) / dot(normalize(i.dir), -UNITY_MATRIX_V[2].xyz);
        float3 a, bb, b;
        WaterIOP(a, bb, b);
        t = exp(-(a + b) * dist) * _UnderwaterExposure;
        float3 L = normalize(_WorldSpaceLightPos0.xyz);
        float3 Ed = _LightColor0.rgb * saturate(L.y) + UNITY_PI * ShadeSH9(float4(0, 1, 0, 1));
        inscatter = Ed * UnderwaterRadiance(a, bb, i.depth) * (1.0 - exp(-(a + b) * dist)) * _UnderwaterExposure;
    }

    float4 fragDim(v2f i) : SV_Target
    {
        float3 t, s;
        Fog(i, t, s);
        return float4(t, 1.0);
    }

    float4 fragGlow(v2f i) : SV_Target
    {
        float3 t, s;
        Fog(i, t, s);
        return float4(s, 1.0);
    }
    ENDCG

    SubShader
    {
        // After the transparents, so particles under the water fade too.
        Tags { "Queue"="Transparent+100" "RenderType"="Transparent" "IgnoreProjector"="True" }
        Cull Front ZWrite Off ZTest Always
        Stencil { Ref 128 ReadMask 128 Comp NotEqual }

        // The fade is per colour, so two passes: dim the scene, then add the water's glow.
        Pass
        {
            Tags { "LightMode"="ForwardBase" }
            Blend DstColor Zero
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment fragDim
            #pragma target 3.0
            ENDCG
        }
        Pass
        {
            Tags { "LightMode"="ForwardBase" }
            Blend One One
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment fragGlow
            #pragma target 3.0
            ENDCG
        }
    }
}
