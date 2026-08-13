# Builds the command line tools. The Xcode project builds the library, the
# sample apps and the test suite; it has no targets for these.
#
#   make            all three tools into bin/
#   make test       run the XCTest suite
#   make clean

CC        := clang
DEPLOY    := -mmacosx-version-min=10.13
INCLUDES  := -I Fountain -I RegexKitLite -I pdf2fountain -I fountain2pdf -I fountain-dump

# FNHTMLScript.h reaches for NSFont, so the library needs the Cocoa umbrella.
COMMON    := $(DEPLOY) $(INCLUDES) -include Cocoa/Cocoa.h -fobjc-arc -framework Cocoa -licucore

LIB_SRC   := $(wildcard Fountain/*.m)
OBJ       := build/obj
BIN       := bin

all: $(BIN)/pdf2fountain $(BIN)/fountain2pdf $(BIN)/fountain-dump

# RegexKitLite predates ARC and will not compile under it. Its OSSpinLock
# deprecation warnings are silenced because the file is vendored third party
# code we are not maintaining.
$(OBJ)/RegexKitLite.o: RegexKitLite/RegexKitLite.m | $(OBJ)
	$(CC) -c -o $@ $< -I RegexKitLite -fno-objc-arc $(DEPLOY) -w

$(BIN)/pdf2fountain: pdf2fountain/main.m pdf2fountain/FNPDFImporter.m $(LIB_SRC) $(OBJ)/RegexKitLite.o | $(BIN)
	$(CC) -o $@ $^ $(COMMON) -framework Quartz

$(BIN)/fountain2pdf: fountain2pdf/main.m fountain2pdf/FNPDFRenderer.m $(LIB_SRC) $(OBJ)/RegexKitLite.o | $(BIN)
	$(CC) -o $@ $^ $(COMMON) -framework CoreText

$(BIN)/fountain-dump: fountain-dump/main.m fountain-dump/FNScriptCheck.m $(LIB_SRC) $(OBJ)/RegexKitLite.o | $(BIN)
	$(CC) -o $@ $^ $(COMMON)

$(BIN) $(OBJ):
	mkdir -p $@

test:
	xcodebuild test -project Fountain.xcodeproj -scheme FountainTests -configuration Debug

clean:
	rm -rf $(BIN) $(OBJ)

.PHONY: all test clean
