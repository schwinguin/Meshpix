class MeshChannel {
  MeshChannel({required this.index, required this.name, this.secret});

  final int index;
  final String name;
  final List<int>? secret;

  bool get isPublic => index == 0;
}
