app := "build/Build/Products/Release/CameraCopy.app"

# Generate the Xcode project and build a Release app
build:
    cd {{justfile_directory()}} && xcodegen generate --quiet && xcodebuild -project CameraCopy.xcodeproj -scheme CameraCopy -configuration Release -derivedDataPath build build -quiet

# Run the unit tests with code coverage, then print coverage per source file
test:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{justfile_directory()}}
    xcodegen generate --quiet
    rm -rf build/TestResults.xcresult
    xcodebuild test -project CameraCopy.xcodeproj -scheme CameraCopy -derivedDataPath build \
        -destination "platform=macOS" -enableCodeCoverage YES -resultBundlePath build/TestResults.xcresult -quiet
    echo ""
    echo "Coverage per file (app sources only):"
    xcrun xccov view --report --files-for-target CameraCopyTests.xctest build/TestResults.xcresult \
        | grep -E "Sources/|^ *(ID|--)" | grep -v "/Tests/" || true

# Click the real update button in a UI test (needs macOS to allow UI automation; asks for a password the first time)
test-ui:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{justfile_directory()}}
    xcodegen generate --quiet
    rm -rf build/UITestResults.xcresult
    # Built as 1.0 so GitHub's latest release is offered; the update replaces only this test copy in build/ui.
    xcodebuild test -project CameraCopy.xcodeproj -scheme CameraCopyUITests -derivedDataPath build/ui \
        -destination "platform=macOS" MARKETING_VERSION=1.0 -resultBundlePath build/UITestResults.xcresult -quiet

# Build and launch
run: build
    open {{justfile_directory()}}/{{app}}

# Build and copy into /Applications
install: build
    rm -rf /Applications/CameraCopy.app && cp -R {{justfile_directory()}}/{{app}} /Applications/

dist_app := "build-dist/Build/Products/Release/CameraCopy.app"
notary_profile := "notary"

# Build a Developer ID–signed, notarized app zipped in dist/ for use on other Macs
package:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{justfile_directory()}}
    xcodegen generate --quiet
    xcodebuild -project CameraCopy.xcodeproj -scheme CameraCopy -configuration Release -derivedDataPath build-dist -destination "generic/platform=macOS" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
        clean build -quiet
    codesign --verify --strict --deep {{dist_app}}
    mkdir -p dist && rm -f dist/CameraCopy.zip
    ditto -c -k --keepParent {{dist_app}} dist/CameraCopy.zip
    if xcrun notarytool history --keychain-profile {{notary_profile}} >/dev/null 2>&1; then
        xcrun notarytool submit dist/CameraCopy.zip --keychain-profile {{notary_profile}} --wait
        xcrun stapler staple {{dist_app}}
        rm dist/CameraCopy.zip && ditto -c -k --keepParent {{dist_app}} dist/CameraCopy.zip
        spctl --assess --type execute -vv {{dist_app}}
    else
        echo "⚠️  Not notarized: no '{{notary_profile}}' keychain profile. Run: xcrun notarytool store-credentials {{notary_profile}}"
    fi
    echo "Built dist/CameraCopy.zip"

# Bumps MARKETING_VERSION, builds with `package`, commits, tags v<version>, pushes, and attaches the zip.
# The app's Check for Updates… menu item then installs it.
# Release a new version to GitHub (kolywater/camera-copy): just release 1.1
release version:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{justfile_directory()}}
    version="{{version}}"
    if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        echo "Usage: just release 1.1   (digits and dots only, no leading 'v')"; exit 1
    fi
    tag="v$version"
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then echo "Error: tag $tag already exists."; exit 1; fi
    # Untracked scratch files are fine; uncommitted changes to tracked files are not.
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
        echo "Error: uncommitted changes. Commit or stash them first."; exit 1
    fi
    if [[ "$(gh api user --jq .login)" != "kolywater" ]]; then
        echo "Error: gh isn't signed in as kolywater. Run: gh auth switch -u kolywater"; exit 1
    fi
    # Nothing ships unless every unit test passes.
    if ! just test; then echo "Error: tests failed, so nothing was released."; exit 1; fi

    echo "Setting MARKETING_VERSION to $version"
    sed -i '' -E "s/(MARKETING_VERSION: )\"?[0-9.]+\"?/\1\"$version\"/" project.yml
    grep -q "MARKETING_VERSION: \"$version\"" project.yml || { echo "Error: couldn't set the version in project.yml"; exit 1; }

    just package
    built=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "{{dist_app}}/Contents/Info.plist")
    if [[ "$built" != "$version" ]]; then echo "Error: built app says $built, expected $version"; exit 1; fi
    zip="dist/CameraCopy-$version.zip"
    cp dist/CameraCopy.zip "$zip"

    git add project.yml
    git diff --cached --quiet || git commit -m "Release $tag"
    git tag "$tag"
    git push origin HEAD
    git push origin "$tag"

    if ! xcrun stapler validate -q "{{dist_app}}" 2>/dev/null; then
        echo "⚠️  This build isn't notarized. In-app updates still work; a first download by hand will need right-click > Open."
    fi
    gh release create "$tag" "$zip" --title "Camera Copy $version" --generate-notes
    echo "Released $tag"
