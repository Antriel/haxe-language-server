package haxeLanguageServer.helper;

import haxeLanguageServer.Configuration.ReturnTypeHintOption;
import haxeLanguageServer.Configuration.FunctionFormattingConfig;

class TypeHelper {
	static final groupRegex = ~/\$(\d+)/g;
	static final parenRegex = ~/^\((.*)\)$/;
	static final argNameRegex = ~/^(\??\w+) : /;
	static final monomorphRegex = ~/^Unknown<\d+>$/;
	static final nullRegex = ~/^Null<(\$\d+)>$/;
	static final packagePathsRegex = ~/((?:_*[a-z]\w*\.)*)(?=_*[A-Z])/g;
	static final subtypePackageRegex = ~/\b[A-Z]\w*\.[A-Z]/;

	static function getCloseChar(c:String):String {
		return switch c {
			case "(": ")";
			case "<": ">";
			case "{": "}";
			default: throw 'unknown opening char $c';
		}
	}

	public static function prepareSignature(type:String):String {
		return switch parseDisplayType(type) {
			case DTFunction(args, ret):
				printFunctionSignature(args, ret, {argumentTypeHints: true, returnTypeHint: Always, useArrowSyntax: false});
			case DTValue(type):
				if (type == null) "" else type;
		}
	}

	public static function printFunctionDeclaration(args:Array<DisplayFunctionArgument>, ret:Null<String>, formatting:FunctionFormattingConfig):String {
		var signature = printFunctionSignature(args, ret, formatting);
		if (formatting.useArrowSyntax)
			return signature + " ->";
		return "function" + signature;
	}

	public static function printFunctionSignature(args:Array<DisplayFunctionArgument>, ret:Null<String>, formatting:FunctionFormattingConfig):String {
		var parens = !formatting.useArrowSyntax || formatting.argumentTypeHints || args.length != 1;
		var result = new StringBuf();
		if (parens)
			result.addChar("(".code);
		for (i in 0...args.length) {
			if (i > 0)
				result.add(", ");
			result.add(printSignatureArgument(i, args[i], formatting.argumentTypeHints));
		}
		if (parens)
			result.addChar(")".code);
		if (shouldPrintReturnType(ret, formatting.returnTypeHint) && !formatting.useArrowSyntax) {
			result.addChar(":".code);
			result.add(getTypeWithoutPackage(ret));
		}
		return result.toString();
	}

	private static function shouldPrintReturnType(ret:Null<String>, option:ReturnTypeHintOption):Bool {
		if (ret == null)
			return false;
		return switch option {
			case Always: true;
			case Never: false;
			case NonVoid: ret != "Void";
		}
	}

	public static function printSignatureArgument(index:Int, arg:DisplayFunctionArgument, typeHints:Bool):String {
		var result = if (arg.name != null) arg.name else std.String.fromCharCode("a".code + index);
		if (arg.opt)
			result = "?" + result;
		if (arg.type != null && typeHints) {
			result += ":";
			result += arg.type;
		}
		return result;
	}

	public static function printFunctionType(args:Array<DisplayFunctionArgument>, ret:Null<String>) {
		var result = new StringBuf();
		result.addChar("(".code);
		for (i in 0...args.length) {
			if (i > 0)
				result.add(", ");
			result.add(printSignatureArgument(i, args[i], true));
		}
		result.add(") -> ");
		result.add(if (ret == null) "Unknown" else ret);
		return result.toString();
	}

	public static function parseFunctionArgumentType(argument:String):DisplayType {
		if (argument.startsWith("?"))
			argument = argument.substr(1);

		var colonIndex = argument.indexOf(":");
		var argumentType = argument.substr(colonIndex + 1);

		return parseDisplayType(unwrapNullable(argumentType));
	}

	public static function unwrapNullable(type:String):String {
		if (type == null)
			return null;
		while (type.startsWith("Null<") && type.endsWith(">")) {
			type = type.substring("Null<".length, type.length - 1);
		}
		return type;
	}

	public static function getTypeWithoutParams(type:String):String {
		if (type == null)
			return null;
		var index = type.indexOf("<");
		if (index >= 0)
			return type.substring(0, index);
		return type;
	}

	public static inline function getTypeWithoutPackage(type:String):String {
		return packagePathsRegex.replace(type, "");
	}

	public static function getModule(packagePath:String):String {
		if (subtypePackageRegex.match(packagePath)) {
			return packagePath.untilLastDot();
		}
		return packagePath;
	}

	public static function parseDisplayType(type:String):DisplayType {
		// replace arrows to ease parsing ">" in type params
		type = type.replace(" -> ", "%");

		// prepare a simple toplevel signature without nested arrows
		// nested arrow can be in () or <> and we don't need to modify them,
		// so we store them separately in `groups` map and replace their occurrence
		// with a group name in the toplevel string
		var toplevel = new StringBuf();
		var groups = new Map();
		var closeStack = new haxe.ds.GenericStack();
		var depth = 0;
		var groupId = 0;
		for (i in 0...type.length) {
			var char = type.charAt(i);
			if (char == "(" || char == "<" || char == "{") {
				depth++;
				closeStack.add(getCloseChar(char));
				if (depth == 1) {
					groupId++;
					groups[groupId] = new StringBuf();
					toplevel.add(char);
					toplevel.add('$$$groupId');
					continue;
				}
			} else if (char == closeStack.first()) {
				closeStack.pop();
				depth--;
			}

			if (depth == 0)
				toplevel.add(char);
			else
				groups[groupId].add(char);
		}

		// process a single type entry, replacing inner content from groups
		// and removing unnecessary parentheses
		function processType(type:String):String {
			type = groupRegex.map(type, function(r) {
				var groupId = Std.parseInt(r.matched(1));
				return groups[groupId].toString().replace("%", "->");
			});
			if (parenRegex.match(type))
				type = parenRegex.matched(1);
			return type;
		}

		// split toplevel signature by the "%" (which is actually "->")
		var parts = toplevel.toString().split("%");

		// get a return or variable type
		var returnType = processType(parts.pop());

		if (monomorphRegex.match(returnType))
			returnType = null;

		// if there is only the return type, it's a variable
		// otherwise `parts` contains function arguments
		if (parts.length > 0) {
			// format function arguments
			var args = new Array<DisplayFunctionArgument>();
			for (i in 0...parts.length) {
				var part = parts[i];

				// get argument name and type
				// if function is not a method, argument name is generated by its position
				var name, type, opt = false;
				if (argNameRegex.match(part)) {
					name = argNameRegex.matched(1);
					if (name.charCodeAt(0) == "?".code) {
						name = name.substring(1);
						opt = true;
					}
					type = argNameRegex.matchedRight();
				} else {
					name = null;
					type = part;
					if (type.charCodeAt(0) == "?".code) {
						type = type.substring(1);
						opt = true;
					}
				}

				// strip Null<T> if argument is optional
				if (opt && nullRegex.match(type))
					type = nullRegex.matched(1);

				type = processType(type);

				// we don't need to include the Void argument
				// because it represents absence of arguments
				if (type == "Void")
					continue;

				var arg:DisplayFunctionArgument = {name: name};
				if (!monomorphRegex.match(type))
					arg.type = type;
				if (opt)
					arg.opt = true;
				args.push(arg);
			}
			return DTFunction(args, returnType);
		} else {
			return DTValue(returnType);
		}
	}
}

typedef DisplayFunctionArgument = {name:Null<String>, ?opt:Bool, ?type:String}

enum DisplayType {
	DTValue(type:Null<String>); // null if monomorph
	DTFunction(args:Array<DisplayFunctionArgument>, ret:Null<String>);
}
