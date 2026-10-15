using Tsukimi;
using UnityEngine;
using VRC.SDKBase;

public partial class ShipSpeed
{
    [TsukimiTest]
    public void RampEasesToTheTarget()
    {
        // 0 -> 15 m/s at 0.3 m/s^2 takes 50 s and covers 0.5 * 15 * 50 = 375 m
        Assert.IsTrue(Mathf.Abs(SpeedOnRamp(0f, 15f, 0.3f, 25.0) - 7.5f) < 1e-4f, "half way");
        Assert.AreEqual(15f, SpeedOnRamp(0f, 15f, 0.3f, 80.0), "reached");
        Assert.IsTrue(System.Math.Abs(DistanceOnRamp(0f, 15f, 0.3f, 50.0) - 375.0) < 1e-3, "ramp distance");
        Assert.IsTrue(System.Math.Abs(DistanceOnRamp(0f, 15f, 0.3f, 60.0) - 525.0) < 1e-3, "then cruising");
        // slowing down mirrors it
        Assert.IsTrue(System.Math.Abs(DistanceOnRamp(15f, 0f, 0.3f, 100.0) - 375.0) < 1e-3, "stopping distance");
    }

    [TsukimiTest]
    public void ChangingTargetMidRampKeepsSpeedAndDistance()
    {
        Mimic.Join();
        acceleration = 0.3f;
        rampStartTime = 0.0;
        rampStartDistance = 0.0;
        rampFrom = 15f;
        rampTo = 15f;
        double t = 1000.0;
        double d = DistanceAt(t);
        SetTarget(5f, t);
        Assert.IsTrue(System.Math.Abs(DistanceAt(t) - d) < 1e-6, "distance continuous");
        Assert.AreEqual(15f, SpeedAt(t), "speed continuous");
        // change again half way down: 15 -> 10 m/s after 16.67 s
        double t2 = t + 5.0 / 0.3;
        double d2 = DistanceAt(t2);
        SetTarget(15f, t2);
        Assert.IsTrue(System.Math.Abs(DistanceAt(t2) - d2) < 1e-6, "distance continuous again");
        Assert.IsTrue(Mathf.Abs(SpeedAt(t2) - 10f) < 1e-3f, "speed continuous again");
    }

    [TsukimiTest]
    public void EveryoneComputesTheSameFlow()
    {
        VRCPlayerApi me = Mimic.Join();
        VRCPlayerApi other = Mimic.Join();
        Mimic.Become(other);
        SetTarget(8f, 500.0);
        double theirs = DistanceAt(600.0);
        Mimic.Become(me);
        Mimic.Deliver();
        Assert.AreEqual(8f, rampTo, "target arrived");
        Assert.IsTrue(System.Math.Abs(DistanceAt(600.0) - theirs) < 1e-6, "same distance");
    }
}
