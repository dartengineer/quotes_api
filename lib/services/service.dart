import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:api_testing/models/models.dart';

class QuoteService {
  static const String baseUrl =
      'https://gomezmig03.github.io/MotivationalAPI/en.json';
  static Future<List<Quote>> fetchQuote() async {
    final response = await http.get(Uri.parse(baseUrl));
    if (response.statusCode == 200) {
      final List<dynamic> jsonData = jsonDecode(response.body);
      return jsonData.map((quote) => Quote.fromJson(quote)).toList();
    } else {
      throw Exception('Failed to load quote');
    }
  }


  static Future<List<Quote>> fetchQuotes(int count, {int offset = 0}) async {
    final allQuotes = await fetchQuote();
    if (offset >= allQuotes.length) {
      return [];
    }
    final end = (offset + count) > allQuotes.length ? allQuotes.length : (offset + count);
    return allQuotes.sublist(offset, end);
  }
}