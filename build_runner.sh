xcodebuild archive \
 -scheme ETTraceRunner \
 -archivePath ./ETTraceRunner.xcarchive \
 -sdk macosx \
 -destination 'generic/platform=macOS' \
 SKIP_INSTALL=NO

cp ETTraceRunner.xcarchive/Products/usr/local/bin/ETTraceRunner ETTraceRunner
