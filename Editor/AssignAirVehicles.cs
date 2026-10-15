using System.Linq;
using UdonSharpEditor;
using UnityEditor;
using UnityEngine;
using VRC.Udon;
using VRC.Udon.Common;

// Fills OceanFFT.airVehicles (cascade 0) with every SaccAirVehicle in the open scenes.
public static class AssignAirVehicles
{
    [MenuItem("Tools/VRCOcean/Assign Air Vehicles")]
    private static void Assign()
    {
        UdonBehaviour[] all = Object.FindObjectsOfType<UdonBehaviour>(true);
        // Udon stores a UdonBehaviour[] field as Component[] on the heap.
        Component[] vehicles = all
            .Where(ub => UdonSharpEditorUtility.GetUdonSharpBehaviourType(ub)?.Name == "SaccAirVehicle")
            .Cast<Component>().ToArray();

        int oceans = 0;
        foreach (UdonBehaviour ub in all)
        {
            if (ub.programSource == null || ub.programSource.name != "OceanFFT") continue;
            if (ub.publicVariables.TryGetVariableValue("cascadeIndex", out int cascade) && cascade != 0) continue;

            Undo.RecordObject(ub, "Assign Air Vehicles");
            if (!ub.publicVariables.TrySetVariableValue("airVehicles", vehicles))
                ub.publicVariables.TryAddVariable(new UdonVariable<Component[]>("airVehicles", vehicles));
            EditorUtility.SetDirty(ub);
            PrefabUtility.RecordPrefabInstancePropertyModifications(ub);
            oceans++;
        }

        Debug.Log($"[VRCOcean] {vehicles.Length} air vehicle(s) -> {oceans} OceanFFT: " +
                  string.Join(", ", vehicles.Select(v => v.gameObject.name)));
    }
}
