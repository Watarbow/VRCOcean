using System.IO;
using UnityEditor;
using UnityEngine;

// OceanFFT writes its per-frame values (time, foam area, ship...) into the material assets, and
// in the editor those changes outlive play mode and end up in the .mat files, so every play left
// a diff that broke `git pull` in other projects. Snapshot the materials on entering play mode and
// put them back on leaving it. Covers the kernel materials TsukimiSharp generates as well.
// SessionState, because entering play mode reloads the domain and clears static fields.
[InitializeOnLoad]
public static class RestoreMaterialsAfterPlay
{
    private const string OceanFFTGuid = "1414dd1bb1b340bdaa7b0fa5dce5e554";   // Scripts/OceanFFT.cs
    private const string Key = "VRCOcean.MaterialSnapshot";

    static RestoreMaterialsAfterPlay()
    {
        EditorApplication.playModeStateChanged += OnPlayModeStateChanged;
    }

    private static void OnPlayModeStateChanged(PlayModeStateChange change)
    {
        if (change == PlayModeStateChange.ExitingEditMode)
        {
            // The clone's folder name can change, so find it from OceanFFT.cs.
            string root = Path.GetDirectoryName(Path.GetDirectoryName(AssetDatabase.GUIDToAssetPath(OceanFFTGuid)));
            if (string.IsNullOrEmpty(root)) return;
            string[] guids = AssetDatabase.FindAssets("t:Material", new[] { root.Replace('\\', '/') });
            SessionState.SetInt(Key, guids.Length);
            for (int i = 0; i < guids.Length; i++)
            {
                string path = AssetDatabase.GUIDToAssetPath(guids[i]);
                SessionState.SetString(Key + i, path + "\n" + EditorJsonUtility.ToJson(AssetDatabase.LoadAssetAtPath<Material>(path)));
            }
        }
        else if (change == PlayModeStateChange.EnteredEditMode)
        {
            int n = SessionState.GetInt(Key, 0);
            for (int i = 0; i < n; i++)
            {
                string[] entry = SessionState.GetString(Key + i, "").Split(new[] { '\n' }, 2);
                SessionState.EraseString(Key + i);
                Material m = entry.Length == 2 ? AssetDatabase.LoadAssetAtPath<Material>(entry[0]) : null;
                if (m != null) EditorJsonUtility.FromJsonOverwrite(entry[1], m);
            }
            SessionState.EraseInt(Key);
        }
    }
}
