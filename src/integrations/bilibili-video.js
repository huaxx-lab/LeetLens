'use strict';

(function exposeBilibiliVideo(root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.BilibiliVideo = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, () => {
  const BVID_PATTERN = /\b(BV[0-9A-Za-z]{10})\b/;

  function extractBvid(value) {
    return String(value || '').match(BVID_PATTERN)?.[1] || '';
  }

  function buildVideoSearchQuery(value) {
    const lines = String(value || '')
      .replace(/【(?:任务|浏览器当前选区|用户输入)】/g, ' ')
      .replace(/https?:\/\/\S+/gi, ' ')
      .replace(/[`*_>#|]/g, ' ')
      .split(/\r?\n/)
      .map(line => line.replace(/\s+/g, ' ').trim())
      .filter(line => line.length >= 2);
    const preferred = lines.find(line => /(?:leetcode|力扣|\b\d{1,4}[.、：:]\s*\S+)/i.test(line)) || lines[0] || '';
    const title = preferred.slice(0, 72).trim();
    if (!title) return 'LeetCode 题解';
    return /(?:leetcode|力扣)/i.test(title) ? `${title} 题解` : `LeetCode ${title} 题解`;
  }

  function buildBilibiliSearchUrl(query) {
    const url = new URL('https://search.bilibili.com/all');
    url.searchParams.set('keyword', String(query || 'LeetCode 题解'));
    return url.toString();
  }

  function decodeHtmlText(value) {
    return String(value || '')
      .replace(/<em[^>]*>/gi, '')
      .replace(/<\/em>/gi, '')
      .replace(/&quot;/gi, '"')
      .replace(/&#39;|&apos;/gi, "'")
      .replace(/&lt;/gi, '<')
      .replace(/&gt;/gi, '>')
      .replace(/&amp;/gi, '&')
      .replace(/\s+/g, ' ')
      .trim();
  }

  // 播放量：搜索卡片里第一条统计项就是播放数，形如「4.6万」「1.2亿」。
  // 站点改版时可能取不到，取不到就返回 0，界面自然不显示。
  function parseCountText(value) {
    const text = String(value || '').replace(/\s+/g, '');
    const match = text.match(/^([\d.]+)(万|亿)?$/);
    if (!match) return 0;
    const base = Number(match[1]);
    if (!Number.isFinite(base)) return 0;
    const unit = match[2] === '亿' ? 1e8 : (match[2] === '万' ? 1e4 : 1);
    return Math.round(base * unit);
  }

  function extractPlayCount(markup) {
    const source = String(markup || '');
    const patterns = [
      /bili-video-card__stats--item[^>]*>[\s\S]{0,240}?<span[^>]*>([\d.]+(?:万|亿)?)<\/span>/i,
      /class="bili-video-card__stats--text"[^>]*>\s*([\d.]+(?:万|亿)?)\s*</i,
      /<span[^>]*class="[^"]*watch-num[^"]*"[^>]*>[\s\S]{0,80}?([\d.]+(?:万|亿)?)\s*</i
    ];
    for (const pattern of patterns) {
      const value = parseCountText(source.match(pattern)?.[1]);
      if (value > 0) return value;
    }
    return 0;
  }

  function formatPlayCount(value) {
    const plays = Math.max(0, Math.round(Number(value) || 0));
    if (!plays) return '';
    if (plays >= 1e8) return `${(plays / 1e8).toFixed(1).replace(/\.0$/, '')} 亿播放`;
    if (plays >= 1e4) return `${(plays / 1e4).toFixed(1).replace(/\.0$/, '')} 万播放`;
    return `${plays} 播放`;
  }

  function extractSearchResults(html, limit = 8) {
    const source = String(html || '');
    const results = [];
    const seen = new Set();
    const linkPattern = /<a\s+href="(?:https?:)?\/\/www\.bilibili\.com\/video\/(BV[0-9A-Za-z]{10})\/?[^\"]*"[^>]*>/gi;
    let match;
    while ((match = linkPattern.exec(source)) && results.length < limit) {
      const bvid = match[1];
      if (seen.has(bvid)) continue;
      seen.add(bvid);
      const nearbyMarkup = source.slice(match.index, match.index + 3200);
      const title = decodeHtmlText(nearbyMarkup.match(/<img[^>]+alt="([^"]*)"/i)?.[1] || '');
      const rawCover = decodeHtmlText(nearbyMarkup.match(/<img[^>]+src="([^"]*)"/i)?.[1] || '');
      const cover = rawCover.startsWith('//') ? `https:${rawCover}` : rawCover;
      results.push({
        bvid,
        title,
        cover: /^https:\/\/[^/]+\.hdslb\.com\//i.test(cover) ? cover : '',
        plays: extractPlayCount(nearbyMarkup)
      });
    }
    return results;
  }

  function semanticText(value) {
    return decodeHtmlText(value)
      .toLowerCase()
      .replace(/leetcode|力扣|题解|java|算法|讲解|视频|教程/g, '')
      .replace(/[^0-9a-z\u3400-\u9fff]+/g, '');
  }

  function problemNumber(value) {
    return String(value || '').match(/(?:leetcode|力扣)?\s*#?(\d{1,4})(?=\s*[.\u3001:\uff1a|\-]|题|\s)/i)?.[1] || '';
  }

  function scoreSearchResult(query, candidate, index = 0) {
    const queryCore = semanticText(query);
    const queryNumber = problemNumber(query);
    const title = String(candidate?.title || '');
    const titleCore = semanticText(title);
    const titleNumber = problemNumber(title);
    let score = -index;
    if (queryCore.length >= 2 && titleCore.includes(queryCore)) score += 100;
    if (titleCore.length >= 4 && queryCore.includes(titleCore)) score += 45;
    if (queryNumber && titleNumber === queryNumber) score += 35;
    else if (queryNumber && titleNumber && titleNumber !== queryNumber) score -= 25;
    if (/leetcode|力扣/i.test(title)) score += 8;
    // 播放量取对数：同等相关度下播放量高的排前面，但不会盖过题号/题名匹配。
    const plays = Math.max(0, Number(candidate?.plays) || 0);
    if (plays > 0) score += Math.min(28, Math.log10(plays + 1) * 5);
    return score;
  }

  function rankSearchResults(query, results) {
    const candidates = Array.isArray(results) ? results : [];
    return candidates
      .map((candidate, index) => ({ ...candidate, score: scoreSearchResult(query, candidate, index) }))
      .sort((a, b) => b.score - a.score)
      .map(({ score, ...candidate }) => candidate);
  }

  function chooseBestSearchResult(query, results) {
    return rankSearchResults(query, results)[0] || null;
  }

  function extractAiVideoResults(response, limit = 16) {
    const outputs = Array.isArray(response?.output) ? response.output : [];
    const sources = outputs.flatMap(item => Array.isArray(item?.action?.sources) ? item.action.sources : []);
    const messageText = outputs
      .flatMap(item => Array.isArray(item?.content) ? item.content : [])
      .map(part => String(part?.text || ''))
      .join('\n');
    const candidates = sources.map(source => ({
      bvid: extractBvid(source?.url),
      title: String(source?.title || '').replace(/\s+/g, ' ').trim(),
      cover: '',
      plays: 0
    }));
    for (const bvid of messageText.match(/BV[0-9A-Za-z]{10}/g) || []) {
      candidates.push({ bvid, title: '', cover: '', plays: 0 });
    }
    const seen = new Set();
    return candidates.filter(candidate => {
      if (!candidate.bvid || seen.has(candidate.bvid)) return false;
      seen.add(candidate.bvid);
      return true;
    }).slice(0, limit);
  }

  function buildBilibiliPlayerUrl(bvid, autoplay = false) {
    const id = extractBvid(bvid);
    if (!id) return '';
    const url = new URL('https://player.bilibili.com/player.html');
    url.searchParams.set('bvid', id);
    url.searchParams.set('p', '1');
    url.searchParams.set('poster', '1');
    url.searchParams.set('danmaku', 'false');
    url.searchParams.set('autoplay', autoplay ? '1' : '0');
    url.searchParams.set('muted', autoplay ? '1' : '0');
    return url.toString();
  }

  return {
    extractBvid,
    buildVideoSearchQuery,
    buildBilibiliSearchUrl,
    extractSearchResults,
    rankSearchResults,
    formatPlayCount,
    chooseBestSearchResult,
    extractAiVideoResults,
    buildBilibiliPlayerUrl
  };
});
