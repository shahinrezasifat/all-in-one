class VideoItem {
  final String id;
  final String title;
  final String author;
  final String duration;
  final String views;
  final String thumbnailUrl;
  final String? channelAvatarUrl;
  final String? channelId;
  final String videoUrl;
  final String uploadDate;
  final String platform;

  const VideoItem({
    required this.id,
    required this.title,
    required this.author,
    this.duration = '3:45',
    this.views = '1.2M views',
    required this.thumbnailUrl,
    this.channelAvatarUrl,
    this.channelId,
    required this.videoUrl,
    this.uploadDate = 'Recently',
    this.platform = 'YouTube',
  });

  factory VideoItem.fromJson(Map<String, dynamic> json) {
    return VideoItem(
      id: json['id'] ?? '',
      title: json['title'] ?? 'Untitled',
      author: json['author'] ?? 'Unknown Creator',
      duration: json['duration'] ?? '',
      views: json['views'] ?? '',
      thumbnailUrl: json['thumbnailUrl'] ?? '',
      channelAvatarUrl: json['channelAvatarUrl'],
      channelId: json['channelId'],
      videoUrl: json['videoUrl'] ?? '',
      uploadDate: json['uploadDate'] ?? '',
      platform: json['platform'] ?? 'YouTube',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'duration': duration,
    'views': views,
    'thumbnailUrl': thumbnailUrl,
    'channelAvatarUrl': channelAvatarUrl,
    'channelId': channelId,
    'videoUrl': videoUrl,
    'uploadDate': uploadDate,
    'platform': platform,
  };
}
