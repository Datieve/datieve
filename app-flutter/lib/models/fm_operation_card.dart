class FmOperationCard {
  final String id;
  final String kind;
  final String label;
  final String status;
  final String message;
  final int createdAt;

  const FmOperationCard({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
    required this.message,
    required this.createdAt,
  });

  FmOperationCard copyWith({
    String? status,
    String? message,
  }) {
    return FmOperationCard(
      id: id,
      kind: kind,
      label: label,
      status: status ?? this.status,
      message: message ?? this.message,
      createdAt: createdAt,
    );
  }
}