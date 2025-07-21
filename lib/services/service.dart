import 'dart:convert';
import 'package:api_testing/models/models.dart';
import 'package:http/http.dart' as http;

class CommentService {
  final String baseUrl = 'https://jsonplaceholder.typicode.com/comments';

  Future<List<CommentModel>> fetchComments({
    required int page,
    required int limit,
  }) async {
    final response = await http.get(
      Uri.parse('$baseUrl?_page=$page&_limit=$limit'),
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((json) => CommentModel.fromJson(json)).toList();
    } else {
      throw Exception("Failed to fetch comments");
    }
  }
}
