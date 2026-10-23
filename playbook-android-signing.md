# Android signing walkthrough

Set up signed APK downloads for an Android app, with optional GitHub Release automation. Google Play setup is outside this walkthrough; the signing choices below preserve the option to use it later.

Examples use Windows PowerShell, Android Studio, and a Gradle project with Kotlin build files (`build.gradle.kts`). Replace `my-app` and `MyApp` with your project's names. Instructions checked on 2 October 2026.

## 1. Choose the signing key for this app

- **App already distributed:** reuse its existing release key. Verify it against a previously published APK using step 5 before publishing an update.
- **New, independent app:** use a dedicated keystore containing one release key. This is a recommended way to keep projects independent, rather than an Android requirement.
- **New release of the same app:** keep its existing key and application ID, and increase its version code. Generating an unrelated key does not preserve ordinary update compatibility. Planned key rotation is a separate procedure. [Android signing](https://developer.android.com/studio/publish/app-signing#considerations)

The **keystore** is the file containing your private signing key. The **alias** is the name of a key inside that file. This guide uses `upload` for a newly created key; the name is arbitrary and does not require Google Play. For an existing key, use its actual alias.

Keep a recoverable backup of the keystore and record its alias and passwords in your password manager. A certificate fingerprint is public identification; it cannot replace the private key. [Key security](https://developer.android.com/studio/publish/app-signing#secure-key)

## 2. Find or create the keystore

Open PowerShell. These commands should work:

```powershell
java -version
keytool -help
```

If Java is not on your PATH, Android Studio normally includes it here. Adjust the path if your installation differs:

```powershell
$env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
```

Use a JDK compatible with your project's Gradle wrapper and Android Gradle Plugin. Signing setup does not require changing the project's SDK levels or upgrading its build tools.

### Existing app: inspect the existing key

Set the full path to your actual keystore. Its filename may have no extension.

```powershell
$keystorePath = 'C:\Users\YOUR_NAME\AndroidSigning\my-app\my-app-release.jks'
keytool -list -v -keystore $keystorePath
```

Enter the keystore password locally when prompted. Find the intended entry and record its **Alias name**, **Entry type: PrivateKeyEntry**, certificate **SHA256** fingerprint, and expiry date. A certificate-only entry cannot sign releases. Use the release key, not Android's development `debug.keystore`. [Keytool reference](https://docs.oracle.com/en/java/javase/21/docs/specs/man/keytool.html)

Skip key creation if you already have the right key.

### New app: create its release key once

This creates a keystore outside the repository. It refuses to use a filename that already exists:

```powershell
$signingDirectory = Join-Path $env:USERPROFILE 'AndroidSigning\my-app'
$keystorePath = Join-Path $signingDirectory 'my-app-release.jks'
New-Item -ItemType Directory -Force -Path $signingDirectory | Out-Null
if (Test-Path -LiteralPath $keystorePath) {
    throw 'This keystore already exists. Inspect and reuse it instead.'
}

keytool -genkeypair -v -storetype JKS -keystore $keystorePath -alias upload -keyalg RSA -keysize 4096 -validity 10000
if ($LASTEXITCODE -ne 0) { throw 'Key generation failed.' }
```

Enter strong passwords when prompted and save them. If you accept the keystore password as the key password, both password fields will use that same value. Certificate identity details are included in the public certificate, so use appropriate developer or organization details. The example sets approximately 27 years of validity. [Key generation options](https://docs.oracle.com/en/java/javase/21/docs/specs/man/keytool.html#the-genkeypair-command)

Run `keytool -list -v -keystore $keystorePath` and make your backup before distributing the first APK.

Add these exclusions to the destination project's `.gitignore` if absent:

```gitignore
# Private Android signing material
*.jks
*.keystore
*.p12
keystore.properties
signing.properties

# Generated release output
dist/
**/build/
```

Keep the keystore outside Git even with these exclusions. Extensionless keystores need an explicit exclusion if stored inside a repository. Ignore rules do not remove files already tracked by Git.

## 3. Set the app identity and release version

Locate the application module's `build.gradle.kts`, commonly `android/app/build.gradle.kts` or `app/build.gradle.kts`.

For a **brand-new app**, its existing `defaultConfig` might contain:

```kotlin
defaultConfig {
    applicationId = "com.yourname.myapp"
    versionCode = 1
    versionName = "1.0.0"
}
```

Choose your own application ID before the first release. For an existing app, preserve its real ID and continue its version sequence; do not reset it to this example.

`versionCode` is the increasing integer Android uses to compare releases. `versionName` is the displayed version. Increase the code for every new release, including releases made through another distribution channel. Google Play currently permits codes up to `2100000000`. [Android versioning](https://developer.android.com/studio/publish/versioning)

The workflow below reads the version from the built APK's metadata. Keep the release version in Gradle and make the Git tag match it: `versionName = "1.2.3"` corresponds to tag `v1.2.3`. Local and automated builds then use the same values. If a project already has another versioning system, adapt the workflow to that system while preserving increasing codes.

## 4. Build a signed APK in Android Studio

1. Open the folder containing the project's `settings.gradle.kts` and Gradle wrapper.
2. Select **File > Sync Project with Gradle Files** and wait for a successful sync.
3. Select **Top menu > Build > Generate Signed App Bundle or APK... > APK**.
4. Select the application module, normally `app`.
5. For **Key store path**, choose **Choose existing** and select this app's keystore.
6. Enter its alias (`upload` if you created it above), keystore password, and key password.
7. Select the **release** build and your destination folder, then finish the build.

Use the build notification's **Locate** link to find the actual output. With the usual destination, it is `android/app/release/app-release.apk`, or `app/release/app-release.apk` when the Android project is the repository root. Flavors and custom destinations change this path. [Android Studio signing workflow](https://developer.android.com/studio/publish/app-signing#sign_release)

## 5. Verify the APK's signature

`apksigner` comes with Android SDK Build Tools. The following selects the newest installed stable Build Tools directory at the usual Windows SDK location. Change `$sdkPath` if your SDK is elsewhere:

```powershell
$sdkPath = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$buildTools = Get-ChildItem -LiteralPath "$sdkPath\build-tools" -Directory |
    Where-Object Name -Match '^\d+\.\d+\.\d+$' |
    Sort-Object { [version]$_.Name } -Descending |
    Select-Object -First 1
if (-not $buildTools) { throw 'Install Android SDK Build Tools first.' }
$apkSigner = Join-Path $buildTools.FullName 'apksigner.bat'
$apkPath = 'C:\path\to\my-app\android\app\release\app-release.apk'

& $apkSigner verify --verbose --print-certs $apkPath
if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed.' }
```

Check **Signer #1 certificate SHA-256 digest** against the certificate's **SHA256** from `keytool`. Ignore colons and letter case when comparing. For an existing app, verify the previously distributed APK as well: its signing certificate should match the new APK's certificate. [Apksigner verification](https://developer.android.com/tools/apksigner#verify)

Before publishing an update, install it over the previous release on a test device and confirm the app starts and retains its data. Keep the older installation in place for this test.

## 6. Configure Gradle signing for automated builds

The Studio wizard handles a manual signed build. Command-line and GitHub builds need the signing configuration below.

Merge this into the application module's existing `android { ... }` block. If it already has a release signing configuration, update that configuration instead of creating a duplicate. Preserve the project's other build settings. This snippet is **Kotlin DSL**; Groovy `build.gradle` files need equivalent Groovy syntax.

```kotlin
android {
    signingConfigs {
        create("release") {
            storeFile = file(
                System.getenv("ANDROID_KEYSTORE_FILE")
                    ?: "release-keystore-not-configured.jks"
            )
            storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: ""
            keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: ""
            keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: ""
        }
    }

    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}
```

The environment supplies credentials at build time. The placeholder is deliberately not a real keystore. Keep debug builds using the development key. Do not put passwords or Base64 keystore contents in Gradle files.

For a local command-line release, run this in a fresh PowerShell window from the repository root. Change the path and alias first; use `'.'` for `$androidDirectory` if Gradle is at the repository root:

```powershell
$androidDirectory = 'android'
$env:ANDROID_KEYSTORE_FILE = 'C:\Users\YOUR_NAME\AndroidSigning\my-app\my-app-release.jks'
$env:ANDROID_KEY_ALIAS = 'upload'

try {
    $env:ANDROID_KEYSTORE_PASSWORD = [Net.NetworkCredential]::new(
        '', (Read-Host 'Keystore password' -AsSecureString)
    ).Password
    $env:ANDROID_KEY_PASSWORD = [Net.NetworkCredential]::new(
        '', (Read-Host 'Key password' -AsSecureString)
    ).Password

    & "$androidDirectory\gradlew.bat" -p $androidDirectory --no-daemon :app:assembleRelease
    if ($LASTEXITCODE -ne 0) { throw 'Release build failed.' }
}
finally {
    foreach ($name in @('ANDROID_KEYSTORE_FILE', 'ANDROID_KEYSTORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
}
```

The usual command-line output is `android/app/build/outputs/apk/release/app-release.apk`. Verify it using step 5. Passwords are read interactively rather than written into command history; they are available to the build process until the `finally` block clears them. [Command-line Android builds](https://developer.android.com/build/building-cmdline)

## 7. Add this project's GitHub signing secrets

In the **destination project's repository**, open **Settings > Secrets and variables > Actions > Secrets > New repository secret**. Create these four secrets:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64 contents of this app's keystore file |
| `ANDROID_KEYSTORE_PASSWORD` | Password for that keystore |
| `ANDROID_KEY_ALIAS` | Existing key alias, such as `upload` |
| `ANDROID_KEY_PASSWORD` | Password for that key; use the keystore password again if they are the same |

The names can be identical across projects because each repository stores its own values. [GitHub Actions secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)

Copy the Base64 value to your clipboard without printing it:

```powershell
$keystorePath = 'C:\Users\YOUR_NAME\AndroidSigning\my-app\my-app-release.jks'
[Convert]::ToBase64String([IO.File]::ReadAllBytes($keystorePath)) | Set-Clipboard
```

Paste it into `ANDROID_KEYSTORE_BASE64`. Base64 is an encoding, not encryption: treat this value like the private keystore. Clear the clipboard afterwards with `Set-Clipboard -Value ''`, and clear any clipboard-history copy if history is enabled.

On the **Variables** tab, create a repository variable named **`ANDROID_SIGNING_CERT_SHA256`**. Set it to the release certificate fingerprint from step 2. Colons and spaces are accepted by the workflow. This is public information, not a password. It lets the workflow reject a valid APK signed with the wrong key, including a debug key.

Use the **certificate fingerprint**, not a SHA-256 hash of the APK or keystore file.

## 8. Add the GitHub Release workflow

Save the following as `.github/workflows/android-release.yml` in the destination repository, or merge the Android steps into its existing release workflow. Do not create two workflows that publish the same release assets.

This template assumes a single `app` module without product flavors. Set `ANDROID_DIR`, `APK_ASSET_NAME`, and `JAVA_VERSION` for that project. It uses GitHub's Windows runner and Android SDK; add any framework-specific setup before Gradle for projects that need Node, Flutter, or other tooling. Use the project's compatible JDK version rather than upgrading its Gradle stack merely to match this example.

```yaml
name: Publish signed Android APK

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: read

env:
  ANDROID_DIR: android
  APK_ASSET_NAME: MyApp-Android.apk
  JAVA_VERSION: '21'

jobs:
  release:
    runs-on: windows-latest
    permissions:
      contents: write
    defaults:
      run:
        shell: pwsh
    steps:
      - uses: actions/checkout@v6

      - uses: actions/setup-java@v5
        with:
          distribution: temurin
          java-version: ${{ env.JAVA_VERSION }}

      - uses: gradle/actions/setup-gradle@v6

      - name: Restore signing key
        env:
          ANDROID_KEYSTORE_BASE64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
        run: |
          if ([string]::IsNullOrWhiteSpace($env:ANDROID_KEYSTORE_BASE64)) {
            throw 'ANDROID_KEYSTORE_BASE64 is missing.'
          }
          $keystorePath = Join-Path $env:RUNNER_TEMP 'android-release.jks'
          [IO.File]::WriteAllBytes($keystorePath, [Convert]::FromBase64String($env:ANDROID_KEYSTORE_BASE64))
          "ANDROID_KEYSTORE_FILE=$keystorePath" >> $env:GITHUB_ENV

      - name: Build and check release
        env:
          ANDROID_KEYSTORE_PASSWORD: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
          ANDROID_KEY_ALIAS: ${{ secrets.ANDROID_KEY_ALIAS }}
          ANDROID_KEY_PASSWORD: ${{ secrets.ANDROID_KEY_PASSWORD }}
        run: |
          foreach ($name in @('ANDROID_KEYSTORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD')) {
            if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
              throw "Required signing secret is missing: $name"
            }
          }
          & "$env:ANDROID_DIR\gradlew.bat" -p $env:ANDROID_DIR --no-daemon :app:assembleRelease :app:lintRelease :app:testDebugUnitTest
          if ($LASTEXITCODE -ne 0) { throw 'Android build or checks failed.' }

          $outputDir = Join-Path $env:ANDROID_DIR 'app/build/outputs/apk/release'
          $metadataPath = Join-Path $outputDir 'output-metadata.json'
          $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
          $outputs = @($metadata.elements)
          if ($outputs.Count -ne 1) { throw 'Adapt this workflow for multiple APK outputs.' }
          $tagVersion = $env:GITHUB_REF_NAME -replace '^v', ''
          if ([string]$outputs[0].versionName -cne $tagVersion) {
            throw 'The tag version must match versionName in the app build.'
          }
          New-Item -ItemType Directory -Force -Path dist | Out-Null
          $apkPath = Join-Path $outputDir $outputs[0].outputFile
          Copy-Item -LiteralPath $apkPath -Destination "dist/$env:APK_ASSET_NAME"
          Write-Output "Release $tagVersion, versionCode $($outputs[0].versionCode)"

      - name: Verify signing certificate and create checksum
        env:
          EXPECTED_CERT_SHA256: ${{ vars.ANDROID_SIGNING_CERT_SHA256 }}
        run: |
          $expected = ($env:EXPECTED_CERT_SHA256 -replace '[:\s]', '').ToLowerInvariant()
          if ($expected -notmatch '^[0-9a-f]{64}$') {
            throw 'Set ANDROID_SIGNING_CERT_SHA256 to the release certificate fingerprint.'
          }
          $buildTools = Get-ChildItem -LiteralPath "$env:ANDROID_HOME\build-tools" -Directory |
            Where-Object Name -Match '^\d+\.\d+\.\d+$' |
            Sort-Object { [version]$_.Name } -Descending |
            Select-Object -First 1
          if (-not $buildTools) { throw 'Android SDK Build Tools were not found.' }
          $apkSigner = Join-Path $buildTools.FullName 'apksigner.bat'
          $verification = & $apkSigner verify --verbose --print-certs "dist/$env:APK_ASSET_NAME" 2>&1
          $verifyExit = $LASTEXITCODE
          $verification | Write-Output
          if ($verifyExit -ne 0) { throw 'APK signature verification failed.' }
          $certificates = [regex]::Matches(
            ($verification -join "`n"),
            '(?m)^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)\s*$'
          )
          if ($certificates.Count -ne 1 -or $certificates[0].Groups[1].Value.ToLowerInvariant() -ne $expected) {
            throw 'The APK was not signed with the expected release key.'
          }
          $hash = (Get-FileHash -LiteralPath "dist/$env:APK_ASSET_NAME" -Algorithm SHA256).Hash.ToLowerInvariant()
          "$hash  $env:APK_ASSET_NAME" | Set-Content -LiteralPath dist/SHA256SUMS.txt -Encoding ascii

      - name: Publish GitHub Release
        uses: softprops/action-gh-release@v3
        with:
          generate_release_notes: true
          fail_on_unmatched_files: true
          files: |
            dist/${{ env.APK_ASSET_NAME }}
            dist/SHA256SUMS.txt

      - name: Remove temporary signing key
        if: ${{ always() }}
        run: |
          $keystorePath = Join-Path $env:RUNNER_TEMP 'android-release.jks'
          if (Test-Path -LiteralPath $keystorePath) {
            Remove-Item -LiteralPath $keystorePath -Force
          }
```

The workflow uses the repository's Gradle wrapper and publishes only after the build, checks, signature verification, and certificate comparison succeed. It restores the key in the runner's temporary directory and removes that copy after the job's work. Maintain the action versions as part of the destination project's normal dependency updates. [Gradle action](https://github.com/gradle/actions), [GitHub Release action](https://github.com/softprops/action-gh-release)

## 9. Publish each new APK release

1. Increase `versionCode` and update `versionName` in the app's version configuration.
2. Test the app, including installing over its previous signed release.
3. Commit the intended source, version, and workflow changes. Review the staged files so private signing material is not included.
4. Push the commit and a new matching version tag. For example, after committing version `1.2.3`, from your release branch:

```powershell
git push
if ($LASTEXITCODE -ne 0) { throw 'Source push failed.' }
git tag -a v1.2.3 -m 'Release v1.2.3'
if ($LASTEXITCODE -ne 0) { throw 'Tag creation failed.' }
git push origin v1.2.3
if ($LASTEXITCODE -ne 0) { throw 'Tag push failed.' }
```

A normal branch push does not trigger this example workflow. The `v*` tag push does. Check **Actions**, then **Releases** for the signed APK and `SHA256SUMS.txt`. Use a new version and tag for each new release; do not replace an already distributed APK under its old release version.

Users download the APK, allow installation from their browser or file manager if Android requests it, and install it. Future downloads should update that app in place when signed with its original key and using the same application ID and a higher version code. This workflow does not add an in-app updater.

## 10. Keep Google Play possible later

Keep the original private key, its backups, the application ID, and the increasing version sequence. APK distribution now does not require a different signing identity later.

If you later choose Google Play:

1. Configure **Play App Signing to import this existing app-signing key** before the first Play rollout. To preserve the same signing identity for direct downloads and Play installs, select the option to export and upload your existing Java-keystore key rather than accepting a new Google-generated app-signing key.
2. Follow the Console's current PEPK instructions to encrypt and export that key locally. Upload the encrypted export through Play Console. Check that Play's **app signing certificate** fingerprint matches your direct APK's certificate.
3. You may use this same key to sign the AAB uploads too. A separate upload key is optional; matching only the upload certificate does not establish that Play-delivered APKs use the same app-signing key. [Play App Signing](https://support.google.com/googleplay/android-developer/answer/9842756?hl=en)
4. Build an AAB with the same application ID, key, and release version values. Inside step 6's `try` block, while the signing environment is set, change the Gradle invocation to:

```powershell
& "$androidDirectory\gradlew.bat" -p $androidDirectory --no-daemon :app:assembleRelease :app:bundleRelease
if ($LASTEXITCODE -ne 0) { throw 'APK/AAB release build failed.' }
```

The usual command-line AAB output is `android/app/build/outputs/bundle/release/app-release.aab`. Alternatively, use **Top menu > Build > Generate Signed App Bundle or APK... > Android App Bundle**, select the existing keystore and alias, then **release**. With the usual Studio destination, the output is `android/app/release/app-release.aab`. [Bundle builds](https://developer.android.com/build/building-cmdline#build_bundle)

An AAB is an upload artifact, not the file users install directly. You can add its build, verification, and upload to the GitHub release workflow later. No Play account, PEPK export, AAB publishing, or Play automation is configured by this guide. Future Play eligibility and requirements must be checked when you decide to publish there.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| Android Studio reports an older Gradle version | Check `gradle/wrapper/gradle-wrapper.properties`, run `gradlew.bat --version` from the Android project folder, then **File > Sync Project with Gradle Files**. If needed, close and reopen that project. Use the Gradle version required by its Android Gradle Plugin. |
| Keystore opens but signing fails | Confirm the alias identifies a `PrivateKeyEntry` and that the key password is correct. It can differ from the keystore password. |
| GitHub reports a missing signing secret | Check the four exact names in the destination repository. This example uses repository secrets; an existing workflow using an environment needs access to that environment's secrets. |
| APK certificate does not match | Compare the alias's certificate, the published APK, and the GitHub fingerprint variable. Fix the wrong key or configuration before distributing the build. |
| APK will not update an existing installation | Check application ID, signing certificate, and version code. A debug installation uses a different key. Replacing the production key is not a repair for an update mismatch. |
| Tag and versionName do not match | Commit the intended app version before creating its matching tag. The example deliberately stops instead of publishing a mislabeled release. |
| Lost keystore | Recover its backup. An APK, certificate, fingerprint, or remembered alias cannot recover the private key. |

When handing this file to another project, ask its maintainer or coding agent to inspect the existing signing and release setup first, reuse any established app identity, and adapt paths and build syntax to that project. Keystore passwords and private key contents should be entered locally or in GitHub secrets, not embedded in this document.
