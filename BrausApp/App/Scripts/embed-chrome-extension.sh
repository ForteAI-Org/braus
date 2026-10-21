#!/bin/sh
#
#  embed-chrome-extension.sh
#  Braus
#
#  Copies the Braus extension into Contents/Resources/ChromeExtension, so the
#  app carries it: Settings, Chrome Profiles prepares a folder of it for the
#  person to load in Chrome, with no checkout of the repository.

set -eu

# The script sandbox reads and writes only the declared paths: the same four files.
source="$PROJECT_DIR/../ChromeExtension"
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ChromeExtension"
mkdir -p "$destination"
for file in manifest.json background.js pair.html pair.js; do
    cp -f "$source/$file" "$destination/$file"
done
