winget download layout facts - OBSERVED on this machine (2026-09-03, winget v1.29.290)

Probe command (scratch dir under %TEMP%, never the real staging):
  winget download --id 7zip.7zip -e -v 26.02 --scope machine --architecture x64 `
    --download-directory <dir> --accept-package-agreements --accept-source-agreements --disable-interactivity

Observed on-disk result for <dir> (FLAT - winget does NOT create a package-Id
subfolder of its own; PakageSync passes a per-package dir as --download-directory):

  <dir>\7-Zip_26.02_Machine_X64_wix_zh-CN.msi   (the installer, 1999872 bytes)
  <dir>\7-Zip_26.02_Machine_X64_wix_zh-CN.yaml  (the generated manifest, 4859 bytes)

Layout facts pinned:
  1. One generated manifest YAML per downloaded installer, written NEXT TO the
     installer. YAML filename pattern:
       <PackageName>_<Version>_<Scope(Machine|User)>_<Arch>_<InstallerType>_<Locale>.yaml
     The installer has the SAME STEM with its real extension. The stem is NOT
     derived from the original InstallerUrl filename - winget RENAMES the file.
  2. The generated YAML is a MERGED manifest (ManifestType: merged) with an
     Installers: list; each installer node carries its own InstallerUrl: and
     InstallerSha256:.
  3. Package dependencies are downloaded into a Dependencies\ SUBDIRECTORY of
     the download-directory, each dependency installer getting its own
     generated YAML next to it (winget-cli PR #3376 + PR #3448; confirmed by
     winget-cli e2e tests src/AppInstallerCLIE2ETests/DownloadCommand.cs).
     The YAML rewrite therefore walks ALL *.yaml recursively, INCLUDING
     Dependencies\ subfolders.
  4. winget download supports --skip-dependencies (default = download
     dependencies). PakageSync does NOT pass it - B needs dependency
     installers too.

Fixture contents:
  7zip.7zip\7-Zip_26.02_Machine_X64_wix_zh-CN.yaml
      REAL captured output of the probe above (unmodified bytes, no BOM, CRLF).
      The installer binary itself is NOT committed; tests create an empty
      sibling file with the same stem before running the rewrite.
  synthetic.SampleApp\
      Hand-written merged manifests: multiple Installer entries, an
      InstallerFallbackUrls list, a Dependencies\ subdirectory YAML, and file
      names containing spaces (URL-path segments must be percent-encoded).
  synthetic.BrokenManifest\
      A manifest YAML with NO sibling installer file - the rewrite must throw
      (used to prove rewrite/leak enforcement fails the export loudly).
