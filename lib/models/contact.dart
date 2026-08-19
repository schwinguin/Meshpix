class MeshContact {
  MeshContact({
    required this.publicKey,
    required this.name,
    this.outPath,
  });

  final List<int> publicKey;
  final String name;
  final List<int>? outPath;

  bool get hasPath => outPath != null && outPath!.isNotEmpty;
}
