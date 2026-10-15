using Tsukimi;
using UnityEngine;

public partial class OceanFFT
{
    // The kernels' Stockham indexing, run on the CPU, must equal a direct inverse DFT.
    [TsukimiTest]
    public void StockhamMatchesInverseDft()
    {
        int n = 8;
        float[] re = new float[n];
        float[] im = new float[n];
        for (int i = 0; i < n; i++) { re[i] = Mathf.Sin(i * 1.3f) + i * 0.25f; im[i] = Mathf.Cos(i * 0.7f) - 0.5f; }

        float[] xr = new float[n];
        float[] xi = new float[n];
        System.Array.Copy(re, xr, n);
        System.Array.Copy(im, xi, n);
        float[] yr = new float[n];
        float[] yi = new float[n];
        for (int span = 1; span < n; span *= 2)
        {
            for (int j = 0; j < n; j++)
            {
                int src = FftSource(j, span);
                float ang = Pi * (j & (span - 1)) / span;
                float wr = Mathf.Cos(ang);
                float wi = Mathf.Sin(ang);
                float pr = xr[src + n / 2] * wr - xi[src + n / 2] * wi;
                float pi = xr[src + n / 2] * wi + xi[src + n / 2] * wr;
                float sg = FftIsLower(j, span) ? 1f : -1f;
                yr[j] = xr[src] + sg * pr;
                yi[j] = xi[src] + sg * pi;
            }
            System.Array.Copy(yr, xr, n);
            System.Array.Copy(yi, xi, n);
        }

        for (int x = 0; x < n; x++)
        {
            float sr = 0f;
            float si = 0f;
            for (int k = 0; k < n; k++)
            {
                float a = 2f * Pi * k * x / n;
                sr += re[k] * Mathf.Cos(a) - im[k] * Mathf.Sin(a);
                si += re[k] * Mathf.Sin(a) + im[k] * Mathf.Cos(a);
            }
            Assert.IsTrue(Mathf.Abs(sr - xr[x]) < 1e-3f, "re mismatch at " + x);
            Assert.IsTrue(Mathf.Abs(si - xi[x]) < 1e-3f, "im mismatch at " + x);
        }
    }

    // In the packed a | b buffer each half must stay a separate transform.
    [TsukimiTest]
    public void PackedFftStaysInHalf()
    {
        int n = 8;
        for (int span = 1; span < n; span *= 2)
            for (int x = 0; x < 2 * n; x++)
            {
                int i = FftPackedSource(x, n, span);
                Assert.AreEqual((x / n) * n + FftSource(x % n, span), i, "source x=" + x + " span=" + span);
                Assert.AreEqual(x / n, (i + n / 2) / n, "pair leaves half x=" + x);
            }
    }

    [TsukimiTest]
    public void SpectrumConstants()
    {
        // wind 10 m/s, fetch 150 km (GodotOceanWaves defaults)
        Assert.IsTrue(Mathf.Abs(JonswapPeakOmega(10f, 150000f) - 0.881f) < 0.005f, "peak omega");
        Assert.IsTrue(Mathf.Abs(JonswapAlpha(10f, 150000f) - 0.00920f) < 0.0001f, "alpha");
        Assert.IsTrue(Mathf.Abs(Tanh(0.5f) - 0.46212f) < 1e-4f, "tanh");
        Assert.IsTrue(Mathf.Abs(Tanh(50f) - 1f) < 1e-4f, "tanh clamps");
        // deep water: w^2 = g k
        Assert.IsTrue(Mathf.Abs(Omega(1f, 100f) - Mathf.Sqrt(9.81f)) < 1e-3f, "dispersion");
        // spectrum peaks near wp
        float wp = 0.881f;
        float a = JonswapAlpha(10f, 150000f);
        Assert.IsTrue(Tma(wp, wp, a, 1000f) > Tma(wp * 0.8f, wp, a, 1000f), "peak > below");
        Assert.IsTrue(Tma(wp, wp, a, 1000f) > Tma(wp * 1.3f, wp, a, 1000f), "peak > above");
    }

    [TsukimiTest]
    public void MeshScaleDoublesWithAltitude()
    {
        Assert.AreEqual(1f, MeshScaleForAltitude(30f, 60f, 64f), "deck height");
        Assert.AreEqual(2f, MeshScaleForAltitude(100f, 60f, 64f), "low flight");
        Assert.AreEqual(32f, MeshScaleForAltitude(1500f, 60f, 64f), "1.5 km");
        Assert.AreEqual(64f, MeshScaleForAltitude(20000f, 60f, 64f), "capped");
    }

    [TsukimiTest]
    public void FlowOffsetStaysExact()
    {
        // 15 m/s on the 23.3 m tile after ~11.6 days of server time: float alone would be off by tiles.
        double t = 1000000.25;
        float f = Wrap(-15.0 * t / 23.3);
        double exact = -15.0 * t / 23.3;
        exact -= System.Math.Floor(exact);
        Assert.IsTrue(f >= 0f && f < 1f, "wrapped into [0, 1)");
        Assert.IsTrue(Mathf.Abs(f - (float)exact) < 1e-5f, "matches double");
        // whole-texel flow steps: 0.62 m on 0.5 m texels moves one texel, keeps 0.12 m for later
        Vector2 step = SnapToGrid(new Vector2(0.62f, -0.2f), 0.5f);
        Assert.IsTrue(Mathf.Abs(step.x - 0.5f) < 1e-6f && step.y == 0f, "snap");
    }
}
