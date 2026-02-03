import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/php_api_client.dart';
import '../storage/user_library.dart';

// v5.0: 队列来源类型
enum QueueSource {
  qishuiRecommend,  // 根据...推荐 (无限汽水补货)
  dailyRecommend,   // 每日推荐 (有限列表 + 汽水补货)
  playlist,         // 歌单 (有限列表, 无汽水补货)
}

// v5.0: 队列上下文，用于追踪队列来源和补货状态
class QueueContext {
  final QueueSource source;
  final String? playlistId;
  final List<String> sourceItemIds;
  final int loadedCount;
  final List<SearchItem> originalList;
  
  const QueueContext({
    required this.source,
    this.playlistId,
    this.sourceItemIds = const [],
    this.loadedCount = 0,
    this.originalList = const [],
  });
  
  bool get hasMoreFromSource => loadedCount < originalList.length;
  
  bool get shouldUseQishuiRefill => 
    source == QueueSource.qishuiRecommend || 
    (source == QueueSource.dailyRecommend && !hasMoreFromSource);
  
  QueueContext copyWith({
    QueueSource? source,
    String? playlistId,
    List<String>? sourceItemIds,
    int? loadedCount,
  }) {
    return QueueContext(
      source: source ?? this.source,
      playlistId: playlistId ?? this.playlistId,
      sourceItemIds: sourceItemIds ?? this.sourceItemIds,
      loadedCount: loadedCount ?? this.loadedCount,
      originalList: this.originalList,
    );
  }
}

class PlayerService extends ChangeNotifier {
  PlayerService._();

  static final instance = PlayerService._();

  final _api = PhpApiClient();
  AudioPlayer? _player;
  final _subs = <StreamSubscription<dynamic>>[];
  final _playlist = ConcatenatingAudioSource(children: []);
  bool _buffering = false;

  SearchItem? _current;
  String _quality = 'lossless';
  String _prefWyy = 'lossless';
  String _prefQq = 'lossless';
  Map<String, String> _qualities = const {};

  List<SearchItem> _queue = const [];
  int _index = 0;

  String _playMode = 'sequence'; // sequence | shuffle | repeat_one
  List<int> _order = const [];
  int _orderPos = 0;

  bool _handlingCompletion = false;
  bool _loadingRecommendations = false;
  bool _qualitiesLoading = false;

  bool _autoAppendEnabled = true;
  int _queueStamp = 0;
  
  // v5.0: 队列上下文，追踪队列来源和补货状态
  QueueContext? _queueContext;

  Duration _savedPosition = Duration.zero;
  Duration _savedDuration = Duration.zero;
  bool _savedWasPlaying = false;

  Timer? _persistTimer;
  DateTime _lastPersistAt = DateTime.fromMillisecondsSinceEpoch(0);
 
  Timer? _heartbeatTimer;
  int _accumulatedSeconds = 0;

  bool _isFavorite = false;

  static const _qOrder = [
    'jymaster',      // WYY: 超清母带
    'master',        // QQ: 臻品母带 3.0
    'sky',           // WYY: 沉浸环绕声
    'jyeffect',      // WYY: 高清环绕声
    'hires',         // QQ/WYY: Hi-Res音质
    'atmos_51',      // QQ: 臻品音质 2.0 (5.1声道)
    'atmos_2',       // QQ: 臻品全景声 2.0
    'flac',          // QQ: SQ 无损品质
    'lossless',      // WYY: 无损音质
    '320',           // QQ: HQ 高品质 320kbps
    'ogg_320',      // QQ: OGG 高品质 320kbps
    'aac_192',       // QQ: AAC 高品质 192kbps
    'ogg_192',       // QQ: OGG 标准 192kbps
    '128',           // QQ: 标准 128kbps
    'standard',       // WYY: 标准音质
    'aac_96',        // QQ: AAC 标准 96kbps
  ];

  SearchItem? get current => _current;
  String get quality => _quality;
  Map<String, String> get qualities => _qualities;
  bool get qualitiesLoading => _qualitiesLoading;

  // 音质优先级列表（从高到低）
  static const List<String> _wyyQualityPriority = [
    'jymaster',  // 超清母带
    'sky',       // 沉浸环绕声
    'jyeffect',  // 高清环绕声
    'hires',     // Hi-Res音质
    'lossless',  // 无损音质
    'exhigh',    // 极高音质
    'standard',   // 标准音质
  ];

  static const List<String> _qqQualityPriority = [
    'atmos_51',  // 臻品音质 2.0 (5.1声道)
    'atmos_2',   // 臻品全景声 2.0
    'master',     // 臻品母带 3.0
    'hires',      // Hi-Res音质
    'flac',      // SQ 无损品质
    '320',        // HQ 高品质 320kbps
    'ogg_320',    // OGG 高品质 320kbps
    'aac_192',    // AAC 高品质 192kbps
    'ogg_192',    // OGG 标准 192kbps
    '128',        // 标准 128kbps
    'aac_96',     // AAC 标准 96kbps
  ];

  bool get isFavorite => _isFavorite;

  bool get playing => _player?.playing ?? false;
  Duration get position => _player?.position ?? _savedPosition;
  Duration get duration => _player?.duration ?? _savedDuration;

  Stream<Duration> get positionStream => _player?.positionStream ?? Stream<Duration>.empty();
  Stream<PlayerState> get playerStateStream => _player?.playerStateStream ?? Stream<PlayerState>.empty();

  bool get hasPrev => _order.isNotEmpty && _orderPos > 0;
  bool get hasNext => _order.isNotEmpty && _orderPos < _order.length - 1;
  bool get isBuffering => _buffering;

  List<SearchItem> get queue => List.unmodifiable(_queue);
  int get index => _index;

  String get playMode => _playMode;

  void _rebuildOrder({required int startIndex}) {
    if (_queue.isEmpty) {
      _order = const [];
      _orderPos = 0;
      return;
    }
    final n = _queue.length;
    startIndex = startIndex.clamp(0, n - 1);
    if (_playMode == 'shuffle') {
      final rest = <int>[for (var i = 0; i < n; i++) if (i != startIndex) i];
      rest.shuffle();
      _order = [startIndex, ...rest];
      _orderPos = 0;
    } else {
      _order = [for (var i = 0; i < n; i++) i];
      _orderPos = startIndex;
    }
  }

  void _ensurePlayer() {
    if (_player != null) return;
    final p = AudioPlayer();
    _player = p;
    _subs.add(
      p.positionStream.listen((pos) {
        _savedPosition = pos;
        notifyListeners();
        if (_savedWasPlaying) {
          final now = DateTime.now();
          if (now.difference(_lastPersistAt) >= const Duration(seconds: 5)) {
            _schedulePersist();
          }
        }
      }),
    );
    _subs.add(
      p.durationStream.listen((dur) {
        _savedDuration = dur ?? _savedDuration;
        notifyListeners();
      }),
    );
    _subs.add(p.playerStateStream.listen(_onPlayerState));
    _subs.add(p.processingStateStream.listen((_) => notifyListeners()));
  }

  void _startHeartbeat() {
    if (_heartbeatTimer != null) return;
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _accumulatedSeconds++;
      if (_accumulatedSeconds >= 30) {
        final delta = _accumulatedSeconds;
        _accumulatedSeconds = 0;
        unawaited(_api.listeningHeartbeat(deltaSeconds: delta));
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _onPlayerState(PlayerState s) {
    notifyListeners();
    print('PlayerState changed: processingState=${s.processingState}, playing=${s.playing}');
    if (s.processingState == ProcessingState.completed) {
      unawaited(_handleTrackCompleted());
    }
    _savedWasPlaying = s.playing;
    _schedulePersist();
    if (s.playing) {
      _startHeartbeat();
    } else {
      _stopHeartbeat();
    }
  }

  void _schedulePersist() {
    final now = DateTime.now();
    if (now.difference(_lastPersistAt) < const Duration(seconds: 2)) {
      _persistTimer ??= Timer(const Duration(seconds: 2), () {
        _persistTimer = null;
        unawaited(_persistState());
      });
      return;
    }
    _lastPersistAt = now;
    unawaited(_persistState());
  }

  Future<void> _persistState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final q = [
        for (final it in _queue)
          {
            'platform': it.platform,
            'name': it.name,
            'artist': it.artist,
            'shareUrl': it.shareUrl,
            'coverUrl': it.coverUrl,
          }
      ];
      await prefs.setString('player.queue', jsonEncode(q));
      await prefs.setInt('player.index', _index);
      await prefs.setString('player.playMode', _playMode);
      await prefs.setString('player.quality', _quality);
      await prefs.setString('player.pref.wyy', _prefWyy);
      await prefs.setString('player.pref.qq', _prefQq);
      _savedPosition = _player?.position ?? _savedPosition;
      _savedDuration = _player?.duration ?? _savedDuration;
      _savedWasPlaying = _player?.playing ?? _savedWasPlaying;
      await prefs.setInt('player.positionMs', _savedPosition.inMilliseconds);
      await prefs.setInt('player.durationMs', _savedDuration.inMilliseconds);
      await prefs.setBool('player.wasPlaying', _savedWasPlaying);
      await prefs.setString('player.currentShareUrl', _current?.shareUrl ?? '');
    } catch (_) {}
  }

  Future<void> restoreState() async {
    const isTest = bool.fromEnvironment('FLUTTER_TEST');
    if (isTest) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = (prefs.getString('player.queue') ?? '').trim();
    if (raw.isEmpty) return;
    final decoded = jsonDecode(raw);
    if (decoded is! List) return;
    final restored = <SearchItem>[];
    for (final v in decoded) {
      if (v is! Map) continue;
      final m = v.cast<String, dynamic>();
      restored.add(SearchItem(
        platform: (m['platform'] as String?) ?? 'qq',
        name: (m['name'] as String?) ?? '',
        artist: (m['artist'] as String?) ?? '',
        shareUrl: (m['shareUrl'] as String?) ?? '',
        coverUrl: (m['coverUrl'] as String?) ?? '',
      ));
    }
    restored.removeWhere((e) => e.shareUrl.isEmpty || e.name.isEmpty);
    if (restored.isEmpty) return;
    _queue = restored;
    _index = (prefs.getInt('player.index') ?? 0).clamp(0, _queue.length - 1);
    _playMode = prefs.getString('player.playMode') ?? 'sequence';
    _quality = prefs.getString('player.quality') ?? 'lossless';
    _prefWyy = prefs.getString('player.pref.wyy') ?? 'lossless';
    _prefQq = prefs.getString('player.pref.qq') ?? 'lossless';
    _savedPosition = Duration(milliseconds: prefs.getInt('player.positionMs') ?? 0);
    _savedDuration = Duration(milliseconds: prefs.getInt('player.durationMs') ?? 0);
    _savedWasPlaying = prefs.getBool('player.wasPlaying') ?? false;
    _current = _queue[_index];
    _rebuildOrder(startIndex: _index);
    notifyListeners();
    if (_savedWasPlaying) {
      try {
        await _resumeCurrentFromSavedPosition();
      } catch (_) {}
    }
  }

  Future<void> _resumeCurrentFromSavedPosition() async {
    final cur = _current;
    if (cur == null) return;
    _ensurePlayer();
    final pos = _savedPosition;
    final r = await _api.parse(url: cur.shareUrl, quality: _quality);
    _qualities = {for (final k in r.qualities.keys) k: k};
    final picked = r.qualities[_quality]?.url.isNotEmpty == true ? r.qualities[_quality]!.url : r.best.url;
    if (picked.isEmpty) return;
    await _player!.setUrl(picked);
    if (pos > Duration.zero) await _player!.seek(pos);
    await _player!.play();
    notifyListeners();
  }

  String _extractSongId(SearchItem item) {
    final platform = item.platform;
    final raw = item.shareUrl;
    if (platform == 'wyy') {
      final m = RegExp(r'\bid=(\d+)\b').firstMatch(raw);
      if (m != null) return m.group(1)!;
      final m2 = RegExp(r'\b(\d{3,})\b').firstMatch(raw);
      if (m2 != null) return m2.group(1)!;
      return raw;
    }
    if (platform == 'qq') {
      final m = RegExp(r'songDetail\/([0-9A-Za-z]+)\b').firstMatch(raw);
      if (m != null) return m.group(1)!;
      return raw;
    }
    return raw;
  }

  Future<void> _handleTrackCompleted() async {
    if (_player == null) return;
    if (_queue.isEmpty) return;

    try {
      if (_playMode == 'repeat_one') {
        await _player!.seek(Duration.zero);
        await _player!.play();
        return;
      }

      if (hasNext) {
        // 检查 _orderPos + 1 是否在有效范围内
        final nextPos = _orderPos + 1;
        if (nextPos < _order.length) {
          _orderPos = nextPos;
          _index = _order[_orderPos];
          
          // 获取下一首歌曲的音质偏好
          final nextSong = _queue[_index];
          final platformQuality = nextSong.platform == 'wyy' ? _prefWyy : _prefQq;
          
          debugPrint('Auto-playing next song: index=$_index (platform=${nextSong.platform}, quality=$platformQuality)');
          await playItem(_queue[_index], quality: platformQuality);
          
          // 确保 playItem 后 _orderPos 正确同步
          if (_order.isNotEmpty) {
            final p = _order.indexOf(_index);
            if (p >= 0) _orderPos = p;
          }
        } else {
          // _orderPos 已经在边界，尝试重新构建顺序
          debugPrint('Order at boundary, rebuilding and checking next');
          _rebuildOrder(startIndex: _index);
          if (hasNext) {
            await next();
          } else {
            debugPrint('No next song, loading recommendations');
            await _loadRecommendations(autoPlayIfEnded: true);
          }
        }
      } else {
        // 没有下一首，尝试加载推荐
        debugPrint('No next song, loading recommendations');
        await _loadRecommendations(autoPlayIfEnded: true);
      }
    } catch (e, st) {
      debugPrint('ERROR in _handleTrackCompleted: $e');
    }
  }

  Future<void> _loadRecommendations({required bool autoPlayIfEnded}) async {
    if (!_autoAppendEnabled) return;
    if (_loadingRecommendations) return;
    
    // v5.0: 如果有队列上下文，使用 v5.0 补货逻辑
    if (_queueContext != null) {
      debugPrint('[Queue] _loadRecommendations: context source=${_queueContext!.source} loaded=${_queueContext!.loadedCount}/${_queueContext!.originalList.length}');
      if (_queueContext!.shouldUseQishuiRefill) {
        debugPrint('[Queue] Using Qishui Refill (shouldUseQishuiRefill=true)');
        _loadingRecommendations = true;
        notifyListeners();
        try {
          await _refillFromQishui();
        } finally {
          _loadingRecommendations = false;
          notifyListeners();
        }
      } else if (_queueContext!.hasMoreFromSource) {
         debugPrint('[Queue] Using Source List Refill');
         // 从原始列表补货
         await _refillFromSourceList();
      } else {
         debugPrint('[Queue] No refill strategy matched');
      }
      // 歌单或其他来源暂不处理或已处理
      return;
    }

    final cur = _current;
    if (cur == null) return;
    final stamp = _queueStamp;
    _loadingRecommendations = true;
    notifyListeners();
    try {
      final songId = _extractSongId(cur);
      final recs = await _api.getRecommendations(songId: songId, source: cur.platform);
      if (recs.isEmpty) return;
      if (!_autoAppendEnabled || stamp != _queueStamp) return;
      final seen = <String>{for (final it in _queue) it.shareUrl};
      final unique = <SearchItem>[];
      for (final it in recs) {
        if (it.shareUrl.isEmpty) continue;
        if (seen.add(it.shareUrl)) unique.add(it);
      }
      if (unique.isEmpty) return;
      final oldLen = _queue.length;
      _queue = [..._queue, ...unique];
      final newLen = _queue.length;
      if (_order.isEmpty) {
        _rebuildOrder(startIndex: _index);
      } else if (_playMode == 'shuffle') {
        final add = <int>[for (var i = oldLen; i < newLen; i++) i];
        add.shuffle();
        _order = [..._order, ...add];
      } else {
        _order = [for (var i = 0; i < newLen; i++) i];
        _orderPos = _index;
      }
      notifyListeners();
      if (autoPlayIfEnded && hasNext) await next();
    } finally {
      _loadingRecommendations = false;
      notifyListeners();
    }
  }

  Future<void> disposeService() async {
    _heartbeatTimer?.cancel();
    _persistTimer?.cancel();
    _persistTimer = null;
    await _persistState();
    for (final s in _subs) await s.cancel();
    await _player?.dispose();
    _player = null;
  }

  void setQueue(List<SearchItem> items, {int startIndex = 0}) {
    _queueStamp += 1;
    _autoAppendEnabled = true;
    _queue = items;
    _index = startIndex.clamp(0, items.isEmpty ? 0 : items.length - 1);
    _rebuildOrder(startIndex: _index);
    notifyListeners();
    _schedulePersist();
  }

  void setPlayMode(String mode) {
    if (!['sequence', 'shuffle', 'repeat_one'].contains(mode)) return;
    if (mode == _playMode) return;
    _playMode = mode;
    _rebuildOrder(startIndex: _index);
    notifyListeners();
    _schedulePersist();
  }

  String _getEffectiveQuality(String platform, String pref) {
    // 优化：优先选择最可能成功的音质
    // 对于QQ：优先选择MP3音质，避免FLAC失败
    // 对于WYY：优先使用用户最后选择的音质（_prefWyy）
    
    if (platform == 'wyy') {
      // WYY优先使用用户手动选择的音质
      if (_qualities.containsKey(_prefWyy)) {
        return _prefWyy;
      }
      // 回退：按优先级顺序选择
      for (final q in _qOrder) {
        if (_qualities.containsKey(q)) {
          return q;
        }
      }
      return _qualities.keys.firstOrNull ?? 'standard';
    }
    
    // QQ：优先选择MP3音质（320/128），避免FLAC失败
    // QQ：优先使用用户手动选择的音质
    if (platform == 'qq') {
      if (_qualities.containsKey(_prefQq)) {
        return _prefQq;
      }
      // 回退：按优先级顺序选择
      for (final q in _qOrder) {
        if (_qualities.containsKey(q)) {
          return q;
        }
      }
      return _qualities.keys.firstOrNull ?? 'standard';
    }
    
    return _qualities.keys.firstOrNull ?? 'standard';
  }

  Future<void> playItem(SearchItem item, {String? quality}) async {
    _ensurePlayer();
    
    // 不要调用 stop()，setUrl 内部会处理，避免 Connection aborted 错误
    
    if (_queue.isEmpty) {
      _queue = [item];
      _index = 0;
      _rebuildOrder(startIndex: 0);
    } else {
      final idx = _queue.indexWhere((e) => e.shareUrl == item.shareUrl);
      if (idx >= 0) {
        _index = idx;
        // 确保 _order 包含当前索引
        if (_order.isNotEmpty && !_order.contains(idx)) {
          // 如果 _order 中不包含当前索引，重新构建
          _rebuildOrder(startIndex: idx);
         } else if (_order.isNotEmpty) {
          final p = _order.indexOf(idx);
          if (p >= 0) {
            _orderPos = p;
          }
        }
      } else {
        // 歌曲不在队列中，添加到队列而不是重置
        _queue = [..._queue, item];
        _index = _queue.length - 1;
        _rebuildOrder(startIndex: _index);
      }
    }
     _current = item;
    final pref = item.platform == 'wyy' ? _prefWyy : _prefQq;
    _quality = quality ?? pref;
    _qualities = const {};
    _qualitiesLoading = true;
    _isFavorite = false;
    // Don't notify yet - wait until all data is ready
    try {
      final r = await _api.parse(url: item.shareUrl, quality: _quality);
      if (r.coverUrl.isNotEmpty) {
        _current = SearchItem(
          platform: item.platform,
          name: item.name,
          artist: item.artist,
          shareUrl: item.shareUrl,
          coverUrl: r.coverUrl,
        );
      }
      _qualities = {for (final e in r.qualities.entries) e.key: e.value.url};
      _qualitiesLoading = false;
      _quality = _getEffectiveQuality(item.platform, quality ?? pref);
      final picked = _qualities[_quality] ?? r.best.url;
      if (picked.isEmpty) throw Exception('empty stream url');
      
      final tag = MediaItem(
        id: item.shareUrl,
        title: item.name,
        artist: item.artist,
        artUri: item.coverUrl.isNotEmpty ? Uri.tryParse(item.coverUrl) : null,
        extras: {'platform': item.platform},
      );
      
      // print('Attempting setAudioSource: $picked');
      try {
        final source = AudioSource.uri(Uri.parse(picked), tag: tag);
        await _player!.setAudioSource(source);
      } catch (e) {
        // print('Audio setUrl error ($picked): $e');
        
        // 如果是连接中断（通常是切歌或暂停导致），不要重试或抛出
        if (e.toString().contains('Connection aborted') || e.toString().contains('interrupted')) {
           return;
        }

        if (picked != r.best.url && r.best.url.isNotEmpty) {
           try {
             final fallbackSource = AudioSource.uri(Uri.parse(r.best.url), tag: tag);
             await _player!.setAudioSource(fallbackSource);
           } catch (e2) {
             if (e2.toString().contains('Connection aborted') || e2.toString().contains('interrupted')) {
               return;
             }
             rethrow;
           }
        } else {
           rethrow;
        }
      }
      await _player!.play();
      await UserLibrary.instance.addRecent(_current!);
      _isFavorite = await UserLibrary.instance.isFavorite(_current!.shareUrl);
      if (_autoAppendEnabled && _queue.isNotEmpty && (_queue.length - 1 - _index) <= 1) {
        unawaited(_loadRecommendations(autoPlayIfEnded: false));
      }
    } finally {
      _qualitiesLoading = false;
      notifyListeners();
      _schedulePersist();
    }
  }

  Future<void> replaceQueueAndPlay(List<SearchItem> items, {int startIndex = 0, String? quality}) async {
    if (items.isEmpty) return;
    setQueue(items, startIndex: startIndex);
    await playItem(_queue[_index], quality: quality);
  }

  Future<void> insertAsNextThenPlay(SearchItem first, List<SearchItem> tail, {String? quality}) async {
    final seen = <String>{};
    final out = <SearchItem>[];
    if (first.shareUrl.isNotEmpty && seen.add(first.shareUrl)) out.add(first);
    for (final it in tail) {
      if (it.shareUrl.isEmpty) continue;
      if (seen.add(it.shareUrl)) out.add(it);
    }
    _autoAppendEnabled = true;
    await replaceQueueAndPlay(out, startIndex: 0, quality: quality);
  }

  Future<void> jumpTo(int idx) async {
    if (_queue.isEmpty) return;
    if (idx < 0 || idx >= _queue.length) return;
    _index = idx;
    if (_order.isNotEmpty) {
      final p = _order.indexOf(idx);
      if (p >= 0) _orderPos = p;
    }
    await playItem(_queue[_index]);
    _schedulePersist();
  }

  Future<void> playFromList(List<SearchItem> items, int startIndex, {String? quality}) async {
    if (items.isEmpty) return;
    setQueue(items, startIndex: startIndex);
    await playItem(_queue[_index], quality: quality);
  }

  List<SearchItem> snapshotQueue() => List<SearchItem>.from(_queue);

  void clearQueue() {
    _queueStamp += 1;
    _autoAppendEnabled = false;
    final cur = _current;
    _queue = cur == null ? const [] : [cur];
    _index = 0;
    _rebuildOrder(startIndex: _index);
    notifyListeners();
    _schedulePersist();
  }

  Future<void> toggle() async {
    if (_current == null) return;
    _ensurePlayer();
    if (_player!.playing) {
      await _player!.pause();
    } else {
      // 如果播放器处于 Idle 状态（例如加载被中断），则重新加载当前歌曲
      if (_player!.processingState == ProcessingState.idle && _current != null) {
        debugPrint('Player is idle, reloading current item: ${_current!.name}');
        await playItem(_current!);
        return;
      }

      if (_player!.duration == null && _current != null) {
        try {
          await _resumeCurrentFromSavedPosition();
          return;
        } catch (_) {}
      }
      await _player!.play();
    }
    notifyListeners();
    _schedulePersist();
  }

  Future<void> seek(Duration d) async {
    if (_player == null) return;
    await _player!.seek(d);
    // 移除手动 notifyListeners，依赖 positionStream/playerStateStream 更新
    // 以解决 iOS 端 Seek 后 UI/歌词跑在音频前面的问题 (AV Sync)
    _schedulePersist();
  }

  Future<void> prev() async {
    if (!hasPrev) return;
    _orderPos -= 1;
    _index = _order[_orderPos];
    await playItem(_queue[_index]);
  }

  Future<void> next() async {
    if (hasNext) {
      _orderPos += 1;
      _index = _order[_orderPos];
      await playItem(_queue[_index]);
      return;
    }
    await _loadRecommendations(autoPlayIfEnded: false);
    if (hasNext) await next();
  }

  Future<void> setQuality(String q) async {
    if (_current == null) return;
    final platform = _current!.platform;
    if (platform == 'wyy') _prefWyy = q;
    else if (platform == 'qq') _prefQq = q;
    if (q == _quality) {
      _schedulePersist();
      return;
    }
    _ensurePlayer();
    final pos = _player!.position;
    _quality = q;
    _qualitiesLoading = true;
    notifyListeners();
    try {
      final r = await _api.parse(url: _current!.shareUrl, quality: _quality);
      _qualities = {for (final e in r.qualities.entries) e.key: e.value.url};
      _qualitiesLoading = false;
      _quality = _getEffectiveQuality(platform, q);
      final picked = _qualities[_quality] ?? r.best.url;
      if (picked.isEmpty) throw Exception('empty stream url');
      try {
        await _player!.setUrl(picked);
      } catch (e) {
        // debugPrint('Audio setUrl error ($picked): $e');
        if (picked != r.best.url && r.best.url.isNotEmpty) {
           // debugPrint('Falling back to best: ${r.best.url}');
           await _player!.setUrl(r.best.url);
        } else {
           rethrow;
        }
      }
      await _player!.seek(pos);
      await _player!.play();
    } finally {
      _qualitiesLoading = false;
      notifyListeners();
      _schedulePersist();
    }
  }

   Future<void> toggleFavoriteCurrent() async {
    final it = _current;
    if (it == null) return;
    await UserLibrary.instance.toggleFavorite(it);
    _isFavorite = await UserLibrary.instance.isFavorite(it.shareUrl);
    notifyListeners();
  }

  // 切换到下一个可用音质（下一级音质）
  Future<void> toggleNextQuality() async {
    if (_current == null) return;
    
    final platform = _current!.platform;
    final currentQuality = _quality;
    
    // 根据平台选择优先级列表
    final qualityPriority = platform == 'wyy' ? _wyyQualityPriority : _qqQualityPriority;
    
    // 找到当前音质在优先级列表中的位置
    final currentIndex = qualityPriority.indexOf(currentQuality);
    if (currentIndex == -1) {
      debugPrint('Current quality not in priority list: $currentQuality');
      return;
    }
    
    // 计算下一个音质（循环到最后一个后回到第一个）
    final nextIndex = (currentIndex + 1) % qualityPriority.length;
    final nextQuality = qualityPriority[nextIndex];
    
    debugPrint('Toggling quality: $currentQuality -> $nextQuality (platform: $platform)');
    await setQuality(nextQuality);
  }

  // 插入歌曲到播放列表顶部并播放
  // 如果当前队列>100首，先清空
  Future<void> insertTopAndPlay(List<SearchItem> items, int playIndex) async {
    if (items.isEmpty) return;
    
    // 如果队列太大，先清空
    if (_queue.length > 100) {
      _queue = [];
      await _playlist.clear();
    }
    
    // 去重：移除已存在的歌曲
    final existingUrls = _queue.map((e) => e.shareUrl).toSet();
    final newItems = items.where((e) => !existingUrls.contains(e.shareUrl)).toList();
    
    // 插入到队列头部
    _queue = [...newItems, ..._queue];
    _queueStamp++;
    _rebuildOrder(startIndex: 0);
    
    // 播放指定索引的歌曲
    if (playIndex >= 0 && playIndex < newItems.length) {
      _index = playIndex;
      _orderPos = _order.indexOf(playIndex);
      await playItem(_queue[playIndex]);
    }
    
    notifyListeners();
  }

  // ==================== v5.0 队列管理方法 ====================
  
  /// 从指定来源初始化播放队列 (限量加载3首)
  Future<void> initQueueFromSource({
    required QueueSource source,
    String? playlistId,
    List<SearchItem>? initialItems,
  }) async {
    debugPrint('[Queue] Initializing from source: $source');
    
    // 确保播放器已初始化
    _ensurePlayer();
    
    // 1. 根据来源加载初始3首
    List<SearchItem> items = [];
    List<String> sourceIds = [];
    
    if (initialItems != null && initialItems.isNotEmpty) {
      items = initialItems.take(3).toList();
      sourceIds = initialItems.map((e) => e.shareUrl).toList();
    } else if (source == QueueSource.qishuiRecommend) {
      items = await _api.getQishuiFeed(count: 3);
    } else if (source == QueueSource.dailyRecommend) {
      final allDaily = await _api.getQishuiFeed(count: 20);
      items = allDaily.take(3).toList();
      sourceIds = allDaily.map((e) => e.shareUrl).toList();
    }
    
    if (items.isEmpty) {
      debugPrint('[Queue] Warning: No items loaded');
      return;
    }
    
    // 2. 初始化上下文
    _queueContext = QueueContext(
      source: source,
      playlistId: playlistId,
      sourceItemIds: sourceIds,
      loadedCount: items.length,
      originalList: initialItems ?? items, // 保存完整列表以便后续加载
    );
    
    debugPrint('[Queue] Context initialized: source=$source, originalList.length=${_queueContext!.originalList.length}, loaded=${_queueContext!.loadedCount}');
    
    // 3. 使用setQueue逻辑设置队列（不清空_playlist）
    _queueStamp += 1;
    _autoAppendEnabled = true;
    _queue = items;
    _index = 0;
    _rebuildOrder(startIndex: 0);
    
    debugPrint('[Queue] Initialized: ${items.length} songs');
    notifyListeners();
    _schedulePersist();
  }
  
  /// 检查并触发队列补货
  Future<void> _checkAndRefillQueue() async {
    if (_queueContext == null) return;
    
    // 播放到倒数第1首时触发补货
    if (_index >= _queue.length - 1) {
      debugPrint('[Queue] Refill triggered at index $_index/${_queue.length}');
      await _refillFromQishui();
    }
  }
  
  /// 从原始列表补货（歌单/每日推荐）
  Future<void> _refillFromSourceList() async {
    final ctx = _queueContext;
    if (ctx == null || !ctx.hasMoreFromSource) return;
    
    debugPrint('[Queue] Refilling from source list (loaded: ${ctx.loadedCount}/${ctx.originalList.length})');
    
    // 加载下3首
    final nextItems = ctx.originalList.skip(ctx.loadedCount).take(3).toList();
    if (nextItems.isEmpty) return;
    
    // 更新 loadedCount
    _queueContext = ctx.copyWith(loadedCount: ctx.loadedCount + nextItems.length);
    
    // 添加到队列
    _queue = [..._queue, ...nextItems];
    _rebuildOrder(startIndex: _index);
    notifyListeners();
  }
  Future<void> _refillFromQishui() async {
    debugPrint('[Queue] Loading from qishui');
    
    // 多获取一些以确保去重后仍有足够歌曲
    final items = await _api.getQishuiFeed(count: 10);
    
    // 去重并只取前3首
    final existing = _queue.map((e) => e.shareUrl).toSet();
    final newItems = items.where((e) => !existing.contains(e.shareUrl)).take(3).toList();
    
    if (newItems.isEmpty) {
      debugPrint('[Queue] Warning: No new songs from qishui');
      return;
    }
    
    _queue = [..._queue, ...newItems];
    _rebuildOrder(startIndex: _index);
    
    debugPrint('[Queue] Added ${newItems.length} from qishui');
    notifyListeners();
  }
  
  /// 心动页面空队列保护
  Future<void> ensureQueueNotEmpty() async {
    if (_queue.isEmpty) {
      debugPrint('[Queue] Empty queue, loading initial songs');
      await initQueueFromSource(source: QueueSource.qishuiRecommend);
      if (_queue.isNotEmpty) {
        await playItem(_queue[0]);
      }
    }
  }
  
  // ==================== v5.0 队列管理方法结束 ====================
}
