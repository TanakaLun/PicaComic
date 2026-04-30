import 'package:flutter/cupertino.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/network/base_comic.dart';

@immutable
class NhentaiComicBrief extends BaseComic {
  @override
  final String title;
  @override
  final String cover;
  @override
  final String id;
  final String lang;
  @override
  final List<String> tags;

  const NhentaiComicBrief(this.title, this.cover, this.id, this.lang, this.tags);

  @override
  String get description => lang;

  @override
  String get subTitle => id;

  @override
  bool get enableTagsTranslation => true;
}

class NhentaiHomePageData {
  final List<NhentaiComicBrief> popular;
  List<NhentaiComicBrief> latest;
  int page = 1;

  NhentaiHomePageData(this.popular, this.latest);
}

class NhentaiComic with HistoryMixin {
  String id;
  @override
  String title;
  @override
  String subTitle;
  @override
  String cover;
  Map<String, List<String>> tags;
  bool favorite;
  List<String> thumbnails;
  List<NhentaiComicBrief> recommendations;
  String token;
  List<String> pages;

  NhentaiComic({
    required this.id,
    required this.title,
    required this.subTitle,
    required this.cover,
    required this.tags,
    required this.favorite,
    required this.thumbnails,
    required this.recommendations,
    required this.token,
    this.pages = const [],
  });

  factory NhentaiComic.fromMap(Map<String, dynamic> map) {
    return NhentaiComic(
      id: map["id"] ?? "",
      title: map["title"] ?? "",
      subTitle: map["subTitle"] ?? "",
      cover: map["cover"] ?? "",
      tags: {},
      favorite: false,
      thumbnails: [],
      recommendations: [],
      token: "",
      pages: [],
    );
  }

  @override
  Map<String, dynamic> toMap() => {
        "id": id,
        "title": title,
        "subTitle": subTitle,
        "cover": cover,
      };

  @override
  HistoryType get historyType => HistoryType.nhentai;

  @override
  String get target => id;
}

class NhentaiComment {
  String userName;
  String avatar;
  String content;
  int date;

  NhentaiComment(this.userName, this.avatar, this.content, this.date);
}