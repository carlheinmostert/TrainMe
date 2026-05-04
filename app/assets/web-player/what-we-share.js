(function () {
  'use strict';

  var params = new URLSearchParams(window.location.search || '');
  var planId = params.get('p');
  var pageTitle = document.getElementById('page-title');
  var greeting = document.getElementById('greeting');
  var stopBtn = document.getElementById('stop-btn');
  var stopHint = document.getElementById('stop-hint');
  var stopConfirm = document.getElementById('stop-confirm');
  var practitionerName = 'your practitioner';

  if (!planId) {
    // Generic variant — no plan context.
    return;
  }

  // Enable the stop-sharing button. Try localStorage first (set by the
  // web player when consent is granted). If no session ID in localStorage
  // (e.g. user arrived from the mobile app, not Safari), create one via
  // the startAnalyticsSession RPC so the button always works when a
  // plan context is present.
  var sessionKey = 'homefit-session-id-' + planId;
  var sessionId = null;
  try { sessionId = localStorage.getItem(sessionKey); } catch (_) {}

  function wireStopButton(sid) {
    stopBtn.disabled = false;
    stopHint.textContent = '';

    stopBtn.addEventListener('click', function () {
      stopBtn.disabled = true;
      stopBtn.textContent = 'Stopping\u2026';

      window.HomefitApi.revokeAnalyticsConsent(planId, sid).then(function () {
        stopBtn.style.display = 'none';
        stopConfirm.style.display = 'block';
        stopConfirm.textContent = 'Stopped. ' + practitionerName +
          ' won\'t see new data from this plan.';
        try {
          localStorage.setItem('homefit-analytics-consent-' + planId, 'no');
        } catch (_) {}
      }).catch(function () {
        stopBtn.disabled = false;
        stopBtn.textContent = 'Stop sharing for this plan';
        stopHint.textContent = 'Something went wrong. Please try again.';
        stopHint.style.color = '#EF4444';
      });
    });
  }

  if (sessionId) {
    wireStopButton(sessionId);
  } else {
    // No localStorage session — create one on the fly.
    window.HomefitApi.startAnalyticsSession(planId, 'what-we-share')
      .then(function (sid) {
        if (sid) {
          try { localStorage.setItem(sessionKey, sid); } catch (_) {}
          wireStopButton(sid);
        }
        // If null, analytics disabled for this client — button stays disabled.
      })
      .catch(function () {
        // RPC failed — button stays disabled.
      });
  }

  // Contextual variant — fetch practitioner name for personalised greeting.
  window.HomefitApi.getPlanSharingContext(planId).then(function (ctx) {
    if (!ctx || !ctx.practitioner_name) return;

    practitionerName = ctx.practitioner_name;
    var practiceName = ctx.practice_name || '';
    var clientFirst = ctx.client_first_name || '';

    pageTitle.textContent = 'What ' + practitionerName +
      (practiceName ? ' at ' + practiceName : '') +
      ' sees about your exercises.';

    if (clientFirst) {
      greeting.textContent = 'Hi ' + clientFirst + '. Here\'s what\'s being shared.';
    }

    // Update the stop-confirm message with the real practitioner name if
    // the user hasn't already clicked the button.
    if (stopConfirm.style.display === 'block') {
      stopConfirm.textContent = 'Stopped. ' + practitionerName +
        ' won\'t see new data from this plan.';
    }
  }).catch(function (err) {
    // Network error — page stays in generic mode with the button still
    // enabled (if session ID was found above).
    try { console.warn('[homefit] get_plan_sharing_context failed:', err); } catch (_) {}
  });
})();
