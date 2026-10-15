// Bow spray, drawn from the particle state FoamSim.shader pass 1 writes (OceanFFT cascade 0 sets
// _SprayState). One camera-facing quad per particle (Meshes/SprayQuads.asset: uv = corner,
// uv2 = the particle's position texel). Lit with a two-lobe Henyey-Greenstein phase function
// (droplets scatter mostly forward: spray glows against the sun). No refraction, light is only
// added through the alpha, so the hull behind never doubles.
// A particle smaller than 1.5 px keeps 1.5 px and loses alpha instead (same energy), so far
// spray doesn't flicker.
Shader "VRCOcean/Spray"
{
    Properties
    {
        [NoScaleOffset] _SprayState ("Spray State (runtime)", 2D) = "black" {}
        _Color ("Droplet Albedo", Color) = (0.9, 0.92, 0.93, 1)
        _Opacity ("Opacity", Range(0, 1)) = 0.4
        _Size ("Size (m)", Float) = 2.4
        _ForwardG ("Forward Lobe g", Range(0, 0.99)) = 0.8
        _BackG ("Back Lobe g", Range(-0.99, 0)) = -0.3
        _ForwardWeight ("Forward Lobe Weight", Range(0, 1)) = 0.75
    }
    SubShader
    {
        Tags { "Queue"="Transparent" "RenderType"="Transparent" "IgnoreProjector"="True" }
        Pass
        {
            Tags { "LightMode"="ForwardBase" }
            Blend One OneMinusSrcAlpha
            ZWrite Off
            Cull Off
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fog
            #pragma target 4.5
            #include "UnityCG.cginc"
            #include "Lighting.cginc"

            sampler2D _SprayState;
            float4 _Color;
            float _Opacity, _Size, _ForwardG, _BackG, _ForwardWeight;

            struct appdata
            {
                float4 vertex : POSITION;
                float2 corner : TEXCOORD0;
                float2 cell : TEXCOORD1;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct v2f
            {
                float4 pos : SV_POSITION;
                float4 uv : TEXCOORD0;       // xy = corner, z = seed, w = age / life
                float4 col : TEXCOORD1;      // rgb = radiance, a = alpha
                UNITY_FOG_COORDS(2)
                UNITY_VERTEX_OUTPUT_STEREO
            };

            float HG(float c, float g)
            {
                return (1.0 - g * g) / pow(max(1.0 + g * g - 2.0 * g * c, 1e-4), 1.5);   // x 4 pi
            }

            v2f vert (appdata v)
            {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                float4 p = tex2Dlod(_SprayState, float4(v.cell, 0, 0));
                float4 s = tex2Dlod(_SprayState, float4(v.cell + float2(0.5, 0.0), 0, 0));
                float seed = s.w;
                float life = lerp(1.2, 3.0, frac(seed * 7.13));   // as FoamSim pass 1
                float mist = 1.0 - frac(seed * 13.7) * frac(seed * 13.7);   // low drag time = fine mist
                float t = p.w / life;
                bool alive = seed > 0.0 && t < 1.0;

                // Atomizes as it flies: grows, thins out.
                float size = _Size * lerp(0.4, 1.4, mist) * (0.35 + 1.3 * sqrt(saturate(t)));
                float alpha = _Opacity * lerp(1.0, 0.45, mist) * saturate(t * 20.0) * pow(1.0 - saturate(t), 1.5);

                float3 cam = _WorldSpaceCameraPos;
                float dist = max(length(p.xyz - cam), 0.1);
                float px = size * _ScreenParams.y * 0.5 * unity_CameraProjection._m11 / dist;
                if (px < 1.5) { alpha *= (px / 1.5) * (px / 1.5); size *= 1.5 / px; }

                float ang = seed * 40.0;
                float2 cs = float2(cos(ang), sin(ang));
                float2 c = float2(v.corner.x * cs.x - v.corner.y * cs.y, v.corner.x * cs.y + v.corner.y * cs.x);
                float3 right = UNITY_MATRIX_V[0].xyz;
                float3 up = UNITY_MATRIX_V[1].xyz;
                float3 wp = p.xyz + (right * c.x + up * c.y) * (0.5 * size);
                o.pos = alive ? UnityWorldToClipPos(wp) : float4(0, 0, -1, 1);
                o.uv = float4(v.corner, seed, saturate(t));

                float3 L = normalize(_WorldSpaceLightPos0.xyz);
                float cosT = dot(normalize(p.xyz - cam), L);
                float phase = lerp(HG(cosT, _BackG), HG(cosT, _ForwardG), _ForwardWeight);
                // Dense spray scatters many times and turns isotropic: half single (HG), half multiple.
                float3 sun = _LightColor0.rgb * (0.5 + 0.5 * min(phase, 6.0)) * 0.8 * saturate(L.y * 4.0);
                o.col = float4(_Color.rgb * (sun + ShadeSH9(float4(0, 1, 0, 1))), alpha);
                UNITY_TRANSFER_FOG(o, o.pos);
                return o;
            }

            float Noise(float2 x)
            {
                float2 i = floor(x);
                float2 f = frac(x);
                f = f * f * (3.0 - 2.0 * f);
                float4 h = frac(sin(float4(dot(i, float2(127.1, 311.7)), dot(i + float2(1, 0), float2(127.1, 311.7)),
                                            dot(i + float2(0, 1), float2(127.1, 311.7)), dot(i + 1.0, float2(127.1, 311.7)))) * 43758.5453);
                return lerp(lerp(h.x, h.y, f.x), lerp(h.z, h.w, f.x), f.y);
            }

            fixed4 frag (v2f i) : SV_Target
            {
                float r2 = dot(i.uv.xy, i.uv.xy);
                float puff = saturate(1.0 - r2);
                // Breaks up into droplets as it ages (dissolve, as GodotOceanWaves' sea spray).
                float2 q = i.uv.xy * 2.3 + i.uv.z * 61.0;
                float n = 0.65 * Noise(q) + 0.35 * Noise(q * 2.7 + 13.0);
                float a = i.col.a * saturate(puff * 1.8 - n * (0.35 + 0.8 * i.uv.w));
                float3 col = i.col.rgb;
                UNITY_APPLY_FOG(i.fogCoord, col);
                return fixed4(col * a, a);
            }
            ENDCG
        }
    }
}
