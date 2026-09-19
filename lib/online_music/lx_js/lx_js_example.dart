// 完整链路示例：导入自定义源脚本 -> 拿 sources -> 取 musicUrl -> 播放/下载。
//
// 用的是社区在用的真实脚本（聚合 API，v3），一字未改：
// https://raw.githubusercontent.com/pdone/lx-music-source/main/juhe/latest.js
// 它只有两步：GET {base}/init.conf 拿音源表，POST {base}/{source} 取直链。

import 'package:sylvakru/online_music/lx_js/lx_js_bridge.dart';
import 'package:sylvakru/online_music/lx_js/lx_js_source.dart';

/// 真实脚本原文（未做任何翻译/改写）。
const String lxJuheSampleScript = r'''/*! * @name 聚合API接口 (CF) * @description v3 * @version 3 * @author lerd */
let{stringify:t,parse:a}=JSON;let x=(r)=>{throw new Error(r)};let{EVENT_NAMES:n,request:b,on,send:y,version:v}=globalThis.lx;let A='https://api.music.lerd.dpdns.org';let h=(u,o={method:'GET'})=>new Promise((s,j)=>{b(u,o,(e,r)=>{if(e)return j(e);s(r)})});h(A+'/init.conf').then(r=>{if(r.body.code!==200)x("脚本初始化失败");let U=r.body.data;if(U.update.version>v)y(n.updateAlert,U.update);y(n.inited,U.init);}).catch(e=>x(e));on(n.request,async({action,source,info})=>{let r=await h(`${A}/${source}`,{method:'POST',body:t(info),headers:{'Content-Type':'application/json'}});let B=r.body;if(B.code===200)return B.data.url;else if(B.code===303){let S=a(t(B.data));let D=S.request;let F=S.response;try{let z=await h(encodeURI(D.url),D.options);if(F.check.key.reduce((a,c)=>a&&a[c],z)==F.check.value){let u=F.url.reduce((a,c)=>a&&a[c],z);if(u.startsWith("http"))return u;}}catch(e){x(e)}}else x(B.msg);});''';

/// 跑一遍全链路，返回播放直链。失败抛 [LxJsException]。
///
/// ```dart
/// final url = await runLxJsMusicUrlExample();
/// ```
Future<String> runLxJsMusicUrlExample({
  String script = lxJuheSampleScript,
  String source = 'kw',
  String quality = '128k',
  Map<String, dynamic>? musicInfo,
}) async {
  // 1. 注入 lx 并执行脚本，等 lx.send('inited')。
  final sources = await lxJsSources.load(
    script: script,
    meta: const LxScriptMeta(name: '聚合API接口 (CF)', version: '3'),
  );
  lxJsLog('脚本声明的音源: ${sources.keys.join(', ')}');

  // 2. 挑一个音质（歌曲自身音质 ∩ 脚本声明）。
  final info = musicInfo ?? _sampleMusicInfo(source);
  final available = lxJsSources.qualitysOf(source, const ['128k', '320k', 'flac']);
  final type = available.contains(quality)
      ? quality
      : (available.isEmpty ? '128k' : available.first);

  // 3. 走 request 事件取直链：JS -> lx.request -> Dio -> 校验 http(s) 且 <=2048。
  final url = await lxJsSources.getMusicUrl(source, info, type);
  lxJsLog('$source/$type 直链: $url');
  return url;
}

/// lx 旧格式的歌曲对象（脚本 POST 给接口的 body）。
Map<String, dynamic> _sampleMusicInfo(String source) => {
  'name': '晴天',
  'singer': '周杰伦',
  'source': source,
  'songmid': '123456',
  'interval': '04:29',
  'albumName': '叶惠美',
  'img': '',
  'typeUrl': <String, dynamic>{},
  'albumId': '0',
};
