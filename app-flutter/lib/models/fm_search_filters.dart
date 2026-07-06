class FmSearchFilters {
  final String sizeMinVal;
  final String sizeMinUnit;
  final String sizeMaxVal;
  final String sizeMaxUnit;
  final String createdRange;
  final String modifiedRange;
  final String typeKind;

  const FmSearchFilters({
    this.sizeMinVal = '',
    this.sizeMinUnit = 'MB',
    this.sizeMaxVal = '',
    this.sizeMaxUnit = 'MB',
    this.createdRange = '',
    this.modifiedRange = '',
    this.typeKind = 'all',
  });

  FmSearchFilters copyWith({
    String? sizeMinVal,
    String? sizeMinUnit,
    String? sizeMaxVal,
    String? sizeMaxUnit,
    String? createdRange,
    String? modifiedRange,
    String? typeKind,
  }) {
    return FmSearchFilters(
      sizeMinVal: sizeMinVal ?? this.sizeMinVal,
      sizeMinUnit: sizeMinUnit ?? this.sizeMinUnit,
      sizeMaxVal: sizeMaxVal ?? this.sizeMaxVal,
      sizeMaxUnit: sizeMaxUnit ?? this.sizeMaxUnit,
      createdRange: createdRange ?? this.createdRange,
      modifiedRange: modifiedRange ?? this.modifiedRange,
      typeKind: typeKind ?? this.typeKind,
    );
  }
}