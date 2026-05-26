xcodebuild archive \
 -scheme ETTraceRunner \
 -archivePath ./ETTraceRunner.xcarchive \
 -sdk macosx \
 -destination 'generic/platform=macOS' \
 SKIP_INSTALL=NO

if [ -n "$SIGNING_IDENTITY" ]; then
  codesign --entitlements ./ETTrace/ETTraceRunner/ETTraceRunner.entitlements -f -s "$SIGNING_IDENTITY" ETTraceRunner.xcarchive/Products/usr/local/bin/ETTraceRunner
fi

cp ETTraceRunner.xcarchive/Products/usr/local/bin/ETTraceRunner ETTraceRunner
