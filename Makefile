# macOS only — this Linux box cannot compile the app.
.PHONY: gen run test demo qa

gen:
	xcodegen generate

APP = $$(ls -d ~/Library/Developer/Xcode/DerivedData/UsageOverview-*/Build/Products/Debug/UsageOverview.app | head -1)
BIN = $(APP)/Contents/MacOS/UsageOverview

run: gen
	xcodebuild -scheme UsageOverview -configuration Debug build
	open "$(APP)"

demo: gen
	xcodebuild -scheme UsageOverview -configuration Debug build
	USAGE_OVERVIEW_DEMO=1 "$(BIN)" &

# Force-expanded demo for visual QA / screenshots. Launch binary so env vars stick.
qa: gen
	xcodebuild -scheme UsageOverview -configuration Debug build
	pkill -f 'UsageOverview.app/Contents/MacOS/UsageOverview' 2>/dev/null || true
	sleep 0.3
	USAGE_OVERVIEW_DEMO=1 USAGE_OVERVIEW_FORCE_EXPANDED=1 "$(BIN)" &
