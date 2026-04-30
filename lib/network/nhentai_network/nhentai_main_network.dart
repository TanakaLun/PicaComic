import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/cloudflare.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/nhentai_network/tags.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/time.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:pica_comic/pages/pre_search_page.dart';
import '../app_dio.dart';
import 'models.dart';

export 'models.dart';

class NhentaiNetwork {
  factory NhentaiNetwork() => _cache ?? (_cache = NhentaiNetwork._create());

  NhentaiNetwork._create();

  static NhentaiNetwork? _cache;

  SingleInstanceCookieJar? cookieJar;

  bool logged = false;

  String baseUrl = "https://nhentai.net";
  String apiBaseUrl = "https://nhentai.net/api/v2";

  late Dio dio;

  Future<void> init() async {
    cookieJar = SingleInstanceCookieJar.instance;
    for (var cookie in cookieJar!.loadForRequest(Uri.parse(baseUrl))) {
      if (cookie.name == "sessionid") {
        logged = true;
      }
    }
    dio = logDio(BaseOptions(
      headers: {
        "Accept":
            "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        "Accept-Language": "zh-CN,zh-TW;q=0.9,zh;q=0.8,en-US;q=0.7,en;q=0.6",
        "Referer": "$baseUrl/",
      },
      validateStatus: (i) => i == 200 || i == 302,
    ));
    dio.interceptors.add(CookieManagerSql(cookieJar!));
    dio.interceptors.add(CloudflareInterceptor());
  }

  void logout() async {
    logged = false;
    cookieJar!.delete(Uri.parse(baseUrl), "sessionid");
  }

  Future<Res<String>> get(String url) async {
    if (cookieJar == null) await init();
    try {
      var res = await dio.get<String>(url, options: Options(followRedirects: false));
      if (res.statusCode == 302) {
        var path = res.headers["Location"]?.first ??
            res.headers["location"]?.first ??
            "";
        return get(Uri.parse(url).replace(path: path).toString());
      }
      return Res(res.data);
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<String>> post(String url, dynamic data, [Map<String, String>? headers]) async {
    if (cookieJar == null) await init();
    try {
      var res = await dio.post<String>(url, data: data, options: Options(headers: headers));
      return Res(res.data);
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<dynamic>> getApi(String path, {Map<String, dynamic>? params}) async {
    var uri = Uri.parse("$apiBaseUrl$path").replace(queryParameters: params);
    var res = await get(uri.toString());
    if (res.error) return Res.fromErrorRes(res);
    try {
      return Res(jsonDecode(res.data!));
    } catch (e) {
      return Res(null, errorMessage: "JSON parse error: $e");
    }
  }

  NhentaiComicBrief _parseComicFromApi(Map<String, dynamic> json, {bool useThumbnail = true}) {
    var id = json["id"].toString();
    var thumbPath = json["thumbnail"] as String? ?? "";
    var cover = "https://i.nhentai.net/$thumbPath";
    var title = json["english_title"] ?? json["japanese_title"] ?? "Unknown";

    List<int> tagIds = (json["tag_ids"] as List?)?.map((e) => e as int).toList() ?? [];
    String lang = "Unknown";
    if (tagIds.contains(12227)) lang = "English";
    else if (tagIds.contains(6346)) lang = "日本語";
    else if (tagIds.contains(29963)) lang = "中文";

    var tags = tagIds
        .where((id) => nhentaiTags.containsKey(id.toString()))
        .map((id) => nhentaiTags[id.toString()]!)
        .toList();

    // 已修复：改回正确的位置参数
    return NhentaiComicBrief(title, cover, id, lang, tags);
  }

  Future<Res<NhentaiHomePageData>> getHomePage([int? page]) async {
    var popularRes = await getApi("/galleries/popular");
    var latestRes = await getApi("/galleries", params: {"page": page ?? 1});
    if (popularRes.error || latestRes.error) {
      return Res(null, errorMessage: "Failed to load home data");
    }

    List<dynamic> popularJson = popularRes.data;
    Map<String, dynamic> latestJson = latestRes.data;
    List<dynamic> latestList = latestJson["result"];

    var popularComics = popularJson.map((e) => _parseComicFromApi(e)).toList();
    var latestComics = latestList.map((e) => _parseComicFromApi(e)).toList();

    return Res(NhentaiHomePageData(popularComics, latestComics));
  }

  Future<Res<bool>> loadMoreHomePageData(NhentaiHomePageData data) async {
    var res = await getApi("/galleries", params: {"page": data.page + 1});
    if (res.error) return Res.fromErrorRes(res);
    var json = res.data;
    var moreList = json["result"] as List;
    data.latest.addAll(moreList.map((e) => _parseComicFromApi(e)));
    data.page++;
    return const Res(true);
  }

  Future<Res<List<NhentaiComicBrief>>> search(String keyword, int page,
      [NhentaiSort sort = NhentaiSort.recent]) async {
    if (appdata.searchHistory.contains(keyword)) {
      appdata.searchHistory.remove(keyword);
    }
    appdata.searchHistory.add(keyword);
    appdata.writeHistory();

    var params = {
      "query": keyword,
      "page": page,
      "sort": sort.value.replaceFirst("&sort=", ""),
    };
    var res = await getApi("/galleries/search", params: params);
    if (res.error) return Res.fromErrorRes(res);

    var json = res.data;
    var comics = (json["result"] as List).map((e) => _parseComicFromApi(e)).toList();
    var totalPages = (json["num_pages"] as int?) ?? 1;

    Future.microtask(() {
      try {
        StateController.find<PreSearchController>().update();
      } catch (e) {}
    });

    return Res(comics, subData: totalPages);
  }

  Future<Res<NhentaiComic>> getComicInfo(String id) async {
    if (id.isEmpty) {
      var randomRes = await get("$baseUrl/random");
      if (randomRes.error) return Res.fromErrorRes(randomRes);
      var doc = parse(randomRes.data!);
      var randomId = doc.querySelector("h3#gallery_id")?.text.nums ?? "";
      if (randomId.isEmpty) return Res(null, errorMessage: "Failed to get random comic");
      id = randomId;
    }

    var res = await getApi("/galleries/$id", params: {"include": "comments,related"});
    if (res.error) return Res.fromErrorRes(res);

    var json = res.data;

    var comicId = json["id"].toString();
    var title = json["title"]["pretty"] ?? json["title"]["english"] ?? "Unknown";
    var subTitle = json["title"]["english"] ?? "";
    var coverPath = json["cover"]["path"] as String;
    var cover = "https://i.nhentai.net/$coverPath";

    Map<String, List<String>> tagsMap = {};
    for (var tag in json["tags"]) {
      var type = tag["type"] as String;
      var name = tag["name"] as String;
      var displayType = "${type}s";
      tagsMap.putIfAbsent(displayType, () => []).add(name);
    }
    tagsMap["Pages"] = [json["num_pages"].toString()];
    var uploadDate = DateTime.fromMillisecondsSinceEpoch(json["upload_date"] * 1000);
    tagsMap["Uploaded"] = [timeToString(uploadDate)];

    bool favorite = false;
    String token = "";
    if (logged) {
      var htmlRes = await get("$baseUrl/g/$id/");
      if (!htmlRes.error) {
        var doc = parse(htmlRes.data!);
        var favButton = doc.querySelector("button#favorite > span.text");
        if (favButton?.text != "Favorite") favorite = true;
        try {
          var script = doc.querySelectorAll("script").firstWhere((element) => element.text.contains("csrf_token")).text;
          token = script.split("csrf_token: \"")[1].split("\",")[0];
        } catch (e) {}
      }
    }

    var pagesList = json["pages"] as List;
    var thumbnails = pagesList.map((p) => "https://i.nhentai.net/${p["thumbnail"]}").toList();

    var pageUrls = pagesList.map((p) => "https://i.nhentai.net/${p["path"]}").toList();

    var relatedList = json["related"] as List? ?? [];
    var recommendations = relatedList.map((r) => _parseComicFromApi(r)).toList();

    return Res(NhentaiComic(
      id: comicId,
      title: title,
      subTitle: subTitle,
      cover: cover,
      tags: tagsMap,
      favorite: favorite,
      thumbnails: thumbnails,
      recommendations: recommendations,
      token: token,
      pages: pageUrls,
    ));
  }

  Future<Res<List<String>>> getImages(String id) async {
    var comicRes = await getComicInfo(id);
    if (comicRes.error) return Res.fromErrorRes(comicRes);
    return Res(comicRes.data!.pages);
  }

  Future<Res<List<NhentaiComment>>> getComments(String id) async {
    var res = await get("$baseUrl/api/gallery/$id/comments");
    if (res.error) return Res.fromErrorRes(res);
    try {
      var json = jsonDecode(res.data!);
      return Res((json as List).map((c) => NhentaiComment(
          c["poster"]["username"],
          "https://i3.nhentai.net/${c["poster"]["avatar_url"]}",
          c["body"],
          c["post_date"])).toList());
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<List<NhentaiComicBrief>>> getFavorites(int page) async {
    if (!logged) return const Res(null, errorMessage: "login required");
    var res = await get("$baseUrl/favorites/?page=$page");
    if (res.error) return Res.fromErrorRes(res);

    var document = parse(res.data!);
    var comicDoms = document.querySelectorAll("div.gallery");
    var comics = <NhentaiComicBrief>[];

    for (var dom in comicDoms) {
      var id = dom.attributes["data-id"] ?? dom.querySelector("a")?.attributes["href"]?.split('/')[2] ?? "";
      if (id.isEmpty) continue;

      var imgElement = dom.querySelector("img");
      var img = imgElement?.attributes["src"] ?? "";
      var title = dom.querySelector(".caption")?.text ?? "Unknown";

      var langClass = dom.className.split(' ').firstWhere((c) => c.startsWith('lang-'), orElse: () => '');
      var lang = langClass.replaceFirst('lang-', '');
      if (lang == "gb") lang = "English";
      else if (lang == "cn") lang = "中文";
      else if (lang == "jp") lang = "日本語";

      comics.add(NhentaiComicBrief(title, img, id, lang, const []));
    }

    var paginationLinks = document.querySelectorAll("section.pagination > a");
    var lastPagination = paginationLinks.isNotEmpty
        ? paginationLinks.last.attributes["href"]?.split('=').last
        : "1";
    var totalPages = int.tryParse(lastPagination ?? "1") ?? 1;

    return Res(comics, subData: totalPages);
  }

  Future<Res<bool>> favoriteComic(String id, String token) async {
    var res = await post("$baseUrl/api/gallery/$id/favorite", null, {
      "Referer": "$baseUrl/g/$id",
      "X-Csrftoken": token,
      "X-Requested-With": "XMLHttpRequest"
    });
    if (res.error) return Res.fromErrorRes(res);
    return const Res(true);
  }

  Future<Res<bool>> unfavoriteComic(String id, String token) async {
    var res = await post("$baseUrl/api/gallery/$id/unfavorite", null, {
      "Referer": "$baseUrl/g/$id",
      "X-Csrftoken": token,
      "X-Requested-With": "XMLHttpRequest"
    });
    if (res.error) return Res.fromErrorRes(res);
    return const Res(true);
  }

  Future<Res<List<NhentaiComicBrief>>> getCategoryComics(
      String path, int page, NhentaiSort sort) async {
    var parts = path.split('/');
    if (parts.length < 3) return const Res([], subData: 0);
    var type = parts[1];
    var slug = parts[2];

    var params = {
      "page": page,
      "sort": sort.value.replaceFirst("&sort=", ""),
    };

    var res = await getApi("/galleries", params: {"tag": slug, ...params});
    if (res.error) return Res.fromErrorRes(res);

    var json = res.data;
    var comics = (json["result"] as List).map((e) => _parseComicFromApi(e)).toList();
    var totalPages = (json["num_pages"] as int?) ?? 1;

    Future.microtask(() {
      try {
        StateController.find<PreSearchController>().update();
      } catch (e) {}
    });

    return Res(comics, subData: totalPages);
  }
}

enum NhentaiSort {
  recent(""),
  popularToday("popular-today"),
  popularWeek("popular-week"),
  popularMonth("popular-month"),
  popularAll("popular");

  final String value;
  const NhentaiSort(this.value);

  static NhentaiSort fromValue(String value) {
    switch (value) {
      case "":
        return NhentaiSort.recent;
      case "popular-today":
        return NhentaiSort.popularToday;
      case "popular-week":
        return NhentaiSort.popularWeek;
      case "popular-month":
        return NhentaiSort.popularMonth;
      case "popular":
        return NhentaiSort.popularAll;
      default:
        return NhentaiSort.recent;
    }
  }
}
