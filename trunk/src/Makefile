.SILENT:

CP=cp

all: install

install: soiled.swf
	$(CP) soiled.swf ../html/soiled.swf

doc: apidoc apidoc/index.html

apidoc:
	mkdir apidoc

apidoc/index.html: soiled.swf.xml
	cd apidoc && haxedoc ../soiled.swf.xml
	@echo Done

CompileTime.hx:
	date '+class CompileTime { public static var time = "%Y-%m-%d %H:%M:%S";}'> CompileTime.hx

soiled.swf soiled.swf.xml: \
		CharAttributes.hx CharBuffer.hx Client.hx CommandLineHandler.hx \
		compile.hxml Config.hx \
		FontRepository.hx ICharBuffer.hx ICommandLineHandling.hx \
		IFontRepository.hx ITelnetEventListener.hx \
		IVtParserListener.hx MyKeyboard.hx MyKeyboardEvent.hx \
		Telnet.hx Timer.hx \
		VT100.hx VtParser.hx \
		wordCache/*.hx \
		WordWrapper.hx
	@echo Compiling soiled.swf
	$(MAKE) CompileTime.hx
	haxe compile.hxml
	rm CompileTime.hx
