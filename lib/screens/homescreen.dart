// quote_screen.dart
import 'package:api_testing/models/models.dart';
import 'package:api_testing/services/service.dart';
import 'package:flutter/material.dart';

class QuoteScreen extends StatefulWidget {
  const QuoteScreen({super.key});

  @override
  State<QuoteScreen> createState() => _QuoteScreenState();
}

class _QuoteScreenState extends State<QuoteScreen> {
  final ScrollController _scrollController = ScrollController();
  final List<Quote> _quotes = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadMoreQuotes();

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 50 &&
          !_isLoading) {
        _loadMoreQuotes();
      }
    });
  }

  Future<void> _loadMoreQuotes() async {
    setState(() => _isLoading = true);
    final newQuotes = await QuoteService.fetchQuotes(
      10,
      offset: _quotes.length,
    );
    setState(() {
      _quotes.addAll(newQuotes);
      _isLoading = false;
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Quotes")),
      body: ListView.builder(
        controller: _scrollController,
        itemCount: _quotes.length + (_isLoading ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _quotes.length) {
            return _isLoading
                ? Center(child: CircularProgressIndicator())
                : SizedBox.shrink();
          }
          final quote = _quotes[index];
          return Card(
            elevation: 4,
            margin: EdgeInsets.symmetric(vertical: 8),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${quote.id}',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 10),
                  Text(
                    '"${quote.text}"',
                    style: TextStyle(fontSize: 18, fontStyle: FontStyle.italic),
                  ),
                  SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '- ${quote.author}',
                      style: TextStyle(fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
