// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.IO;
using Microsoft.Build.Framework;
using Microsoft.Build.Utilities;

namespace Microsoft.OpenHarmony.Tasks;

/// <summary>
/// Applies an OpenHarmony self-signature (.codesign section) to ELF64 binaries under the
/// target/publish directories. OpenHarmony only executes signed ELF files, and a signed file
/// whose content changed (e.g. the apphost, rewritten on every build) fails with EPERM; files
/// with a still-valid signature are skipped.
///
/// Symbolic links (file and directory links) are never followed: signing through a link would
/// rewrite a file outside the output tree. Foreign .codesign sections are kept and reported
/// instead of being replaced silently; replacing one requires the explicit selfsign --force
/// opt-in.
///
/// This task lives in the workload's task assembly so the platform workload is self-contained
/// and does not depend on an OpenHarmony-patched dotnet SDK.
/// </summary>
public sealed class OpenHarmonyCodesign : Task
{
    [Required]
    public string[] Directories { get; set; } = Array.Empty<string>();

    public override bool Execute()
    {
        foreach (string directory in Directories)
        {
            if (!Directory.Exists(directory))
            {
                continue;
            }

            try
            {
                foreach (string path in ElfSigner.EnumerateFilesWithoutLinks(
                    directory,
                    link => Log.LogWarning("OpenHarmonyCodesign: skipped symbolic link {0}", link)))
                {
                    try
                    {
                        switch (ElfSigner.SignFileInPlace(path))
                        {
                            case ElfSigner.SignOutcome.Signed:
                                Log.LogMessage(MessageImportance.Low, "OpenHarmonyCodesign: signed {0}", path);
                                break;
                            case ElfSigner.SignOutcome.ForeignSignatureRetained:
                                Log.LogWarning("OpenHarmonyCodesign: retained foreign signature on {0}", path);
                                break;
                            case ElfSigner.SignOutcome.NotElf:
                                // Containers/metadata (.hap/.pdb/.json/...) can never be an
                                // executable ELF; the signer rejected them from the header
                                // bytes alone, so they are only recorded for diagnostics.
                                if (ElfSigner.HasNonExecutableExtension(path))
                                {
                                    Log.LogMessage(MessageImportance.Low, "OpenHarmonyCodesign: skipped {0} (known non-executable format)", path);
                                }

                                break;
                        }
                    }
                    catch (Exception ex)
                    {
                        Log.LogError("OpenHarmonyCodesign: failed to sign {0}: {1}", path, ex.Message);
                    }
                }
            }
            catch (Exception ex)
            {
                Log.LogError("OpenHarmonyCodesign: failed to enumerate {0}: {1}", directory, ex.Message);
            }
        }

        return !Log.HasLoggedErrors;
    }
}
