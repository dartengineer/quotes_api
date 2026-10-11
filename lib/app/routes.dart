/// Route paths, kept in one place so screens never hard-code locations.
abstract final class Routes {
  static const home = '/home';
  static const library = '/library';
  static const collections = '/collections';
  static const settings = '/settings';

  static String collection(int id) => '$collections/$id';
  static String document(int id) => '/document/$id';
  static String read(int id) => '/read/$id';
}
