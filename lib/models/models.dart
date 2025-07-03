class Quote {
  final int id;
  final String text;
  final String author;
  final int religion;
  Quote({
    required this.id,
    required this.religion,
    required this.text,
    required this.author,
  });

  factory Quote.fromJson(Map<String, dynamic> json) {
    return Quote(
      text: json['phrase'] ?? 'No quote found',
      author: json['author'] ?? "Unkown Author",
      religion: json['religion'] ?? 0,
      id: json['id'] ?? 0,
    );
  }
}
