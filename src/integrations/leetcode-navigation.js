'use strict';

(function exposeLeetCodeNavigation(root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.LeetCodeNavigation = api;
})(typeof window === 'object' ? window : null, () => {
  const PAGES = new Set(['overview', 'question', 'workspace']);

  function createLeetCodeRoute(value = {}) {
    const page = PAGES.has(value.page) ? value.page : 'overview';
    const slug = page === 'overview' ? '' : String(value.slug || '');
    return {
      page: slug ? page : 'overview',
      slug,
      submissionId: page === 'overview' ? '' : String(value.submissionId || ''),
      origin: String(value.origin || 'overview'),
      overviewScrollTop: Math.max(0, Number(value.overviewScrollTop) || 0),
      questionScrollTop: Math.max(0, Number(value.questionScrollTop) || 0)
    };
  }

  function navigateLeetCodeRoute(current, target, currentScrollTop = 0) {
    const previous = createLeetCodeRoute(current);
    const scrollTop = Math.max(0, Number(currentScrollTop) || 0);
    if (previous.page === 'overview') previous.overviewScrollTop = scrollTop;
    if (previous.page === 'question') previous.questionScrollTop = scrollTop;
    return createLeetCodeRoute({ ...previous, ...target });
  }

  return { createLeetCodeRoute, navigateLeetCodeRoute };
});
