package haxeLanguageServer.features;

import jsonrpc.CancellationToken;
import jsonrpc.ResponseError;
import jsonrpc.Types.NoData;
import haxe.display.Display;
import languageServerProtocol.protocol.TypeDefinition;

class GotoTypeDefinitionFeature {
	final context:Context;

	public function new(context) {
		this.context = context;
		context.languageServerProtocol.onRequest(TypeDefinitionRequest.type, onGotoTypeDefinition);
	}

	public function onGotoTypeDefinition(params:TextDocumentPositionParams, token:CancellationToken, resolve:Definition->Void,
			reject:ResponseError<NoData>->Void) {
		var doc = context.documents.get(params.textDocument.uri);
		if (!doc.uri.isFile()) {
			return reject.notAFile();
		}
		context.callHaxeMethod(DisplayMethods.GotoTypeDefinition, {file: doc.uri.toFsPath(), contents: doc.content, offset: doc.offsetAt(params.position)},
			token, locations -> {
			resolve(locations.map(location -> {
				{
					uri: location.file.toUri(),
					range: location.range
				}
			}));
			return null;
		}, reject.handler());
	}
}
