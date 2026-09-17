import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/src/models/models.dart';
void main() {
 test('assistant tool collections are independent per message', () {
   final a = ChatMessage(role: 'assistant');
   final b = ChatMessage(role: 'assistant');
   a.addTool(ToolActivity(name: 'terminal'));
   expect(a.tools, hasLength(1));
   expect(b.tools, isEmpty);
 });
}
