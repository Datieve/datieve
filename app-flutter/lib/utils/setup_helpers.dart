import '../src/rust/bridge.dart';

extension SetupStateCopy on SetupStateDto {
  SetupStateDto copyWith({
    int? step,
    String? stepTitle,
    String? stepDesc,
    String? friendlyName,
    String? adminUsername,
    String? adminCode,
    List<String>? watchedPaths,
    bool? excludeHidden,
    List<String>? exclusionPatterns,
    List<SetupUserDto>? users,
    String? manageUsername,
    String? managePassword,
    String? confirmSummary,
  }) {
    return SetupStateDto(
      step: step ?? this.step,
      stepTitle: stepTitle ?? this.stepTitle,
      stepDesc: stepDesc ?? this.stepDesc,
      friendlyName: friendlyName ?? this.friendlyName,
      adminUsername: adminUsername ?? this.adminUsername,
      adminCode: adminCode ?? this.adminCode,
      watchedPaths: watchedPaths ?? this.watchedPaths,
      excludeHidden: excludeHidden ?? this.excludeHidden,
      exclusionPatterns: exclusionPatterns ?? this.exclusionPatterns,
      users: users ?? this.users,
      manageUsername: manageUsername ?? this.manageUsername,
      managePassword: managePassword ?? this.managePassword,
      confirmSummary: confirmSummary ?? this.confirmSummary,
    );
  }
}

extension SetupUserCopy on SetupUserDto {
  SetupUserDto copyWith({
    String? username,
    String? code,
    List<String>? allowedPaths,
  }) {
    return SetupUserDto(
      username: username ?? this.username,
      code: code ?? this.code,
      allowedPaths: allowedPaths ?? this.allowedPaths,
    );
  }
}