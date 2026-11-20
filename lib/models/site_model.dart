class SiteModel {
  final String title;
  final String url;
  final String icon;
  final String category;
  final int colorHex;
  final bool isCustom;

  const SiteModel({
    required this.title,
    required this.url,
    required this.icon,
    this.category = 'Social',
    this.colorHex = 0xFFFF7700,
    this.isCustom = false,
  });

  factory SiteModel.fromJson(Map<String, dynamic> json) {
    return SiteModel(
      title: json['title'] ?? '',
      url: json['url'] ?? '',
      icon: json['largeIconUrl'] ?? json['smallIconUrl'] ?? json['icon'] ?? '',
      category: json['category'] ?? 'Social',
      colorHex: json['colorHex'] is int ? json['colorHex'] : 0xFFFF7700,
      isCustom: json['isCustom'] ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'url': url,
    'largeIconUrl': icon,
    'category': category,
    'colorHex': colorHex,
    'isCustom': isCustom,
  };
}
