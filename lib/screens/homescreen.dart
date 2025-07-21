import 'package:api_testing/models/models.dart';
import 'package:api_testing/services/service.dart';
import 'package:flutter/material.dart';

class CommentsPage extends StatefulWidget {
  const CommentsPage({super.key});

  @override
  // ignore: library_private_types_in_public_api
  _CommentsPageState createState() => _CommentsPageState();
}

class _CommentsPageState extends State<CommentsPage> {
  final ScrollController _scrollController = ScrollController();
  List<CommentModel> _comments = [];
  final CommentService _commentService = CommentService();

  int _page = 1;
  final int _limit = 10;
  bool _isLoading = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _fetchComments();

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 100 &&
          !_isLoading &&
          _hasMore) {
        _fetchComments();
      }
    });
  }

  Future<void> _fetchComments() async {
    setState(() => _isLoading = true);

    try {
      final newComments = await _commentService.fetchComments(
        page: _page,
        limit: _limit,
      );

      setState(() {
        _comments = [..._comments, ...newComments];
        _page++;
        _isLoading = false;

        if (newComments.length < _limit) {
          _hasMore = false;
        }
      });
    } catch (e) {
      setState(() => _isLoading = false);
      debugPrint("Error fetching comments: $e");
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Widget buildCommentCard(CommentModel comment) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 2,
      child: ListTile(
        title: Text(comment.name),
        subtitle: Text(comment.body),
        trailing: Text("#${comment.id}"),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Paginated Comments")),
      body: ListView(
        controller: _scrollController,
        children: [
          ..._comments.map(buildCommentCard),
          if (_hasMore || _isLoading)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
