#!/bin/bash

# SourcePrint Release Script
# Automates packaging, signing, GitHub release, and appcast update

set -e  # Exit on error

# Parse arguments
DRY_RUN=false
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Paths
APP_PATH="macos/build/Build/Products/Release/SourcePrint.app"
SIGN_UPDATE_TOOL="macos/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
APPCAST_PATH="appcast.xml"

echo -e "${BLUE}🚀 SourcePrint Release Automation${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}🔍 DRY RUN MODE - No changes will be made${NC}"
fi
echo ""

# Check if app exists
if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}❌ App not found at $APP_PATH${NC}"
    echo "Please run ./build-sourceprint.sh first"
    exit 1
fi

# Extract version and build number
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

echo -e "${GREEN}📦 Found: SourcePrint v$VERSION (Build $BUILD)${NC}"
echo ""

# Ask for release notes
echo -e "${YELLOW}📝 Enter release notes (press Ctrl+D when done):${NC}"
NOTES=$(cat)

if [ -z "$NOTES" ]; then
    NOTES="SourcePrint v$VERSION - Build $BUILD"
fi

# Package the app
echo ""
echo -e "${BLUE}📦 Packaging app...${NC}"
ZIP_NAME="SourcePrint-$VERSION.zip"
ZIP_PATH="macos/build/Build/Products/Release/$ZIP_NAME"

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}Would create: $ZIP_NAME${NC}"
else
    cd macos/build/Build/Products/Release
    rm -f "$ZIP_NAME"
    ditto -c -k --sequesterRsrc --keepParent SourcePrint.app "$ZIP_NAME"
    cd - > /dev/null
    echo -e "${GREEN}✅ Created $ZIP_NAME${NC}"
fi

# Sign with Sparkle
echo ""
echo -e "${BLUE}🔐 Signing with Sparkle EdDSA...${NC}"

if [ "$DRY_RUN" = true ]; then
    ED_SIGNATURE="<would-generate-signature>"
    LENGTH="<would-calculate-length>"
    echo -e "${YELLOW}Would sign: $ZIP_NAME${NC}"
    echo -e "${YELLOW}Would copy to: ~/Desktop/$ZIP_NAME${NC}"
else
    SIGNATURE_OUTPUT=$("$SIGN_UPDATE_TOOL" "$ZIP_PATH")
    ED_SIGNATURE=$(echo "$SIGNATURE_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
    LENGTH=$(echo "$SIGNATURE_OUTPUT" | grep -o 'length="[^"]*"' | cut -d'"' -f2)
    echo -e "${GREEN}✅ Signature: $ED_SIGNATURE${NC}"
    echo -e "${GREEN}✅ Length: $LENGTH bytes${NC}"

    # Copy to Desktop for GitHub release
    cp "$ZIP_PATH" ~/Desktop/
fi

# Create GitHub release
echo ""
echo -e "${BLUE}🌐 Creating GitHub release v$VERSION...${NC}"

RELEASE_NOTES="## SourcePrint v$VERSION

$NOTES

**Build:** $BUILD
**Release Date:** $(date '+%Y-%m-%d')

---"

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}Would create GitHub release:${NC}"
    echo -e "${YELLOW}  Tag: v$VERSION${NC}"
    echo -e "${YELLOW}  Asset: ~/Desktop/$ZIP_NAME${NC}"
    echo -e "${YELLOW}  Notes: $RELEASE_NOTES${NC}"
else
    gh release create "v$VERSION" ~/Desktop/"$ZIP_NAME" \
        --title "SourcePrint v$VERSION" \
        --notes "$RELEASE_NOTES" || {
        echo -e "${YELLOW}⚠️  Release already exists, uploading asset...${NC}"
        gh release upload "v$VERSION" ~/Desktop/"$ZIP_NAME" --clobber
    }
    echo -e "${GREEN}✅ GitHub release created/updated${NC}"
fi

# Update appcast.xml
echo ""
echo -e "${BLUE}📡 Updating appcast.xml...${NC}"

PUBDATE=$(date -u '+%a, %d %b %Y %H:%M:%S +0000')

# Extract the existing cumulative changelog from the current top item's description
# so we can carry it forward into the new item (Sparkle only shows the latest item's description)
PREV_HISTORY=$(python3 - <<'PYEOF'
import re, sys
content = open("appcast.xml").read()
m = re.search(r'<description><!\[CDATA\[(.*?)\]\]></description>', content, re.DOTALL)
if m:
    print(m.group(1).strip())
PYEOF
)

NEW_ITEM="        <item>
            <title>Version $VERSION</title>
            <description><![CDATA[
                <h2>v$VERSION</h2>
                <ul>
                    <li>$NOTES</li>
                </ul>

                $PREV_HISTORY
            ]]></description>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <enclosure
                url=\"https://github.com/francisqureshi/SourcePrint/releases/download/v$VERSION/SourcePrint-$VERSION.zip\"
                sparkle:edSignature=\"$ED_SIGNATURE\"
                length=\"$LENGTH\"
                type=\"application/octet-stream\"
            />
        </item>

"

# Check if version already exists in appcast
if grep -q "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST_PATH"; then
    echo -e "${YELLOW}⚠️  Version $VERSION (Build $BUILD) already exists in appcast${NC}"
    if [ "$DRY_RUN" = false ]; then
        read -p "Update existing entry? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # Remove existing entry and add new one
            # This is a simple approach - in production you'd want more robust XML editing
            echo -e "${YELLOW}⚠️  Manual appcast update required - entry already exists${NC}"
            echo "Please update appcast.xml manually or delete the existing entry first"
            exit 1
        else
            echo -e "${BLUE}Skipping appcast update${NC}"
            exit 0
        fi
    fi
else
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}Would add to appcast.xml:${NC}"
        echo "$NEW_ITEM"
    else
        # Insert new item after the public key comment using Perl
        perl -i -0pe "s|(<!-- Sparkle Public Key.*?\n\n)|\$1$NEW_ITEM|s" "$APPCAST_PATH"
        echo -e "${GREEN}✅ Appcast updated${NC}"
    fi
fi

# Commit and push
echo ""
echo -e "${BLUE}📤 Committing and pushing to GitHub...${NC}"

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}Would commit and push:${NC}"
    echo -e "${YELLOW}  git add $APPCAST_PATH${NC}"
    echo -e "${YELLOW}  git commit -m \"Release v$VERSION (Build $BUILD)\"${NC}"
    echo -e "${YELLOW}  git push${NC}"
else
    git add "$APPCAST_PATH"
    git commit -m "Release v$VERSION (Build $BUILD)

$NOTES

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
    git push
fi

echo ""
echo -e "${GREEN}✅✅✅ Release complete! ✅✅✅${NC}"
echo ""
echo -e "${BLUE}Summary:${NC}"
echo -e "  Version: ${GREEN}$VERSION${NC}"
echo -e "  Build: ${GREEN}$BUILD${NC}"
echo -e "  GitHub: ${GREEN}https://github.com/francisqureshi/SourcePrint/releases/tag/v$VERSION${NC}"
echo ""
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}🔍 DRY RUN COMPLETE - No changes were made${NC}"
else
    echo -e "${YELLOW}⏳ Wait ~2 minutes for GitHub CDN to refresh appcast, then users can update!${NC}"
fi
