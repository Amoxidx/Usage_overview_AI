# macOS only — this Linux box cannot compile the app.
.PHONY: gen run test demo

gen:
	xcodegen generate

run: gen
	xcodebuild -scheme UsageOverview -configuration Debug build
	open "$$(ls -d ~/Library/Developer/Xcode/DerivedData/UsageOverview-*/Build/Products/Debug/UsageOverview.app | head -1)"

demo: gen
	USAGE_OVERVIEW_DEMO=1 xcodebuild -scheme UsageOverview -configuration Debug build
	USAGE_OVERVIEW_DEMO=1 open "$$(ls -d ~/Library/Developer/Xcode/DerivedData/UsageOverview-*/Build/Products/Debug/UsageOverview.app | head -1)"

test: gen
	xcodebuild -scheme UsageOverview -configuration Debug test
