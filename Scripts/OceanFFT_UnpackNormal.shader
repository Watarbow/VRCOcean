// This file was generated from a T# kernel. Manual edits are overwritten when it is regenerated.
Shader "Tsukimi/OceanFFT_UnpackNormal"
{
    Properties
    {
        _MainTex ("Source", 2D) = "black" {}
        _Tsk_ab ("ab", 2D) = "black" {}
        _Tsk_prev ("prev", 2D) = "black" {}
        _Tsk_fp ("fp", Vector) = (0, 0, 0, 0)
    }
    SubShader
    {
        Cull Off
        ZWrite Off
        ZTest Always
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.5
            #include "UnityCG.cginc"

            sampler2D _MainTex;
            float4 _MainTex_TexelSize;
            sampler2D _Tsk_ab;
            float4 _Tsk_ab_TexelSize;
            sampler2D _Tsk_prev;
            float4 _Tsk_prev_TexelSize;
            float4 _Tsk_fp;

            struct appdata { float4 vertex : POSITION; float2 uv : TEXCOORD0; };
            struct v2f { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

            // Cell read: Point filtering; out-of-range reads return the edge value (Clamp)
            float4 tsk_load(sampler2D tex, float4 texel, int2 id)
            {
                int2 size = int2((int)texel.z, (int)texel.w);
                id = clamp(id, int2(0, 0), size - int2(1, 1));
                return tex2Dlod(tex, float4((float2(id) + 0.5) * texel.xy, 0.0, 0.0));
            }

            float4 tsk_smooth(sampler2D tex, float4 texel, float2 uv)
            {
                float2 p = uv * float2(texel.z, texel.w) - 0.5;
                float2 i0 = floor(p);
                float2 f = p - i0;
                int2 a = int2((int)i0.x, (int)i0.y);
                float4 c00 = tsk_load(tex, texel, a);
                float4 c10 = tsk_load(tex, texel, int2(a.x + 1, a.y));
                float4 c01 = tsk_load(tex, texel, int2(a.x, a.y + 1));
                float4 c11 = tsk_load(tex, texel, int2(a.x + 1, a.y + 1));
                float4 t0 = c00 + (c10 - c00) * f.x;
                float4 t1 = c01 + (c11 - c01) * f.x;
                return t0 + (t1 - t0) * f.y;
            }

            float4 tsk_wrap(sampler2D tex, float4 texel, int2 id)
            {
                int2 size = int2((int)texel.z, (int)texel.w);
                id = ((id % size) + size) % size;
                return tex2Dlod(tex, float4((float2(id) + 0.5) * texel.xy, 0.0, 0.0));
            }

            float4 tsk_pack16x2(float2 v)
            {
                float2 s = saturate(v) * 65535.0;
                float2 hi = floor(s / 256.0);
                float2 lo = s - hi * 256.0;
                return float4(hi.x, lo.x, hi.y, lo.y) / 255.0;
            }

            float2 tsk_unpack16x2(float4 c)
            {
                float4 b = floor(c * 255.0 + 0.5);
                return float2(b.x * 256.0 + b.y, b.z * 256.0 + b.w) / 65535.0;
            }

            float tsk_clamp(float x, float a, float b)
            {
                return x < a ? a : (x > b ? b : x);
            }

            int tsk_clamp_i(int x, int a, int b)
            {
                return x < a ? a : (x > b ? b : x);
            }

            int tsk_hash(int x)
            {
                int h = x * -1907474333;
                h = h ^ (h >> 15);
                h = h * 896956103;
                h = h ^ (h >> 13);
                h = h * 1702399099;
                return h ^ (h >> 16);
            }

            int tsk_hash2(int x, int y)
            {
                return tsk_hash(x ^ (y * 1702399099));
            }

            float tsk_rand01(int x)
            {
                return (tsk_hash(x) & 16777215) * 0.000000059604645;
            }

            float2 tsk_grad(int h)
            {
                int k = h & 3;
                float gx = (k == 0 || k == 2) ? 1.0 : -1.0;
                float gy = (k == 0 || k == 1) ? 1.0 : -1.0;
                return float2(gx, gy);
            }

            float tsk_fade(float t)
            {
                return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
            }

            float tsk_noise(float2 p)
            {
                int ix = (int)floor(p.x);
                int iy = (int)floor(p.y);
                float fx = p.x - floor(p.x);
                float fy = p.y - floor(p.y);
                float v00 = dot(tsk_grad(tsk_hash2(ix, iy)), float2(fx, fy));
                float v10 = dot(tsk_grad(tsk_hash2(ix + 1, iy)), float2(fx - 1.0, fy));
                float v01 = dot(tsk_grad(tsk_hash2(ix, iy + 1)), float2(fx, fy - 1.0));
                float v11 = dot(tsk_grad(tsk_hash2(ix + 1, iy + 1)), float2(fx - 1.0, fy - 1.0));
                float u = tsk_fade(fx);
                float w = tsk_fade(fy);
                float a = v00 + u * (v10 - v00);
                float b = v01 + u * (v11 - v01);
                return (a + w * (b - a)) * 0.5 + 0.5;
            }

            float tsk_clamp01(float x)
            {
                return x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x);
            }

            float tsk_repeat(float t, float len)
            {
                return tsk_clamp(t - floor(t / len) * len, 0.0, len);
            }

            float tsk_deltaangle(float a, float b)
            {
                float d = tsk_repeat(b - a, 360.0);
                return d > 180.0 ? d - 360.0 : d;
            }

            float tsk_lerpangle(float a, float b, float t)
            {
                return a + tsk_deltaangle(a, b) * tsk_clamp01(t);
            }

            float tsk_movetowards(float current, float target, float maxDelta)
            {
                float d = target - current;
                if (abs(d) <= maxDelta) return target;
                return current + (d >= 0.0 ? 1.0 : -1.0) * maxDelta;
            }

            float tsk_movetowardsangle(float current, float target, float maxDelta)
            {
                float d = tsk_deltaangle(current, target);
                if (-maxDelta < d && d < maxDelta) return target;
                return tsk_movetowards(current, current + d, maxDelta);
            }

            float tsk_pingpong(float t, float len)
            {
                float r = tsk_repeat(t, len * 2.0);
                return len - abs(r - len);
            }

            float tsk_smoothstep(float a, float b, float t)
            {
                t = saturate(t);
                t = -2.0 * t * t * t + 3.0 * t * t;
                return b * t + a * (1.0 - t);
            }

            bool tsk_v2eq(float2 a, float2 b)
            {
                float2 d = a - b;
                return dot(d, d) < 9.9999994e-11;
            }

            bool tsk_v3eq(float3 a, float3 b)
            {
                float3 d = a - b;
                return dot(d, d) < 9.9999994e-11;
            }

            bool tsk_v4eq(float4 a, float4 b)
            {
                float4 d = a - b;
                return dot(d, d) < 9.9999994e-11;
            }

            float u_ShiftSign(int2 u_id)
            {
                return (((u_id.x + u_id.y) & 1) == 0 ? 1.0 : -1.0);
            }
            float u_Jacobian(float u_dxdx, float u_dzdz, float u_dzdx)
            {
                return (1.0 + u_dxdx) * (1.0 + u_dzdz) - u_dzdx * u_dzdx;
            }

            v2f vert(appdata v)
            {
                v2f o;
                o.pos = UnityObjectToClipPos(v.vertex);
                o.uv = v.uv;
                return o;
            }

            float4 frag(v2f i) : SV_Target
            {
                int2 u_id = int2(i.pos.xy);
                float u_s = u_ShiftSign(u_id);
                float4 u_ca = tsk_load(_Tsk_ab, _Tsk_ab_TexelSize, u_id);
                float4 u_cb = tsk_load(_Tsk_ab, _Tsk_ab_TexelSize, int2(u_id.x + ((int)round(i.pos.x / i.uv.x)), u_id.y));
                float u_dhdx = u_ca.w * u_s;
                float u_dhdz = u_cb.x * u_s;
                float u_dxdx = u_cb.y * u_s;
                float u_dzdz = u_cb.z * u_s;
                float u_dzdx = u_cb.w * u_s;
                float u_jac = u_Jacobian(u_dxdx, u_dzdz, u_dzdx);
                float u_foam = tsk_load(_Tsk_prev, _Tsk_prev_TexelSize, u_id).w * exp(-_Tsk_fp.z) + max(0.0, _Tsk_fp.x - u_jac) * _Tsk_fp.y;
                float u_gx = u_dhdx / (1.0 + abs(u_dxdx));
                float u_gz = u_dhdz / (1.0 + abs(u_dzdz));
                return float4(u_gx, u_gz, 0.5 * (u_gx * u_gx + u_gz * u_gz), tsk_clamp01(u_foam));
            }
            ENDCG
        }
    }
}
