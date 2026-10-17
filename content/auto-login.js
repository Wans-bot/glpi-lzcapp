// 懒猫免密登录注入脚本（自包含，凭据内置）
// 生成的包：cloud.lazycat.app.glpi
(function () {
  'use strict';
  // 注入参数由平台按 deploy_params.yml 在安装时解析后经 ctx.params 传入；
  // 优先用面板里真实生效的凭据，避免与安装时自定义的密码不一致。
  var __P = (function () {
    try {
      if (typeof ctx === "object" && ctx && typeof ctx.params === "object" && ctx.params) return ctx.params;
    } catch (e) {}
    return {};
  })();
  if (__P.user) { var __u = String(__P.user); }
  if (__P.password) { var __pw = String(__P.password); }
  var USER = (typeof __u === "string" && __u) ? __u : "glpi";
  var PASS = (typeof __pw === "string" && __pw) ? __pw : "glpi";
  var USER_SEL = "#login_name|input[name=login_name]";
  var PASS_SEL = "#login_password|input[name=login_password]";
  var SUBMIT_SEL = "button[type=submit]|input[type=submit]|form button";
  // 不要用 sessionStorage/localStorage 记"已经登录过"：那种标记在**登出后依然存在**，
  // 于是用户登出后必须手动输密码（官方打回原文："登出之后需要手动输入账号密码"）。
  // 用页面级内存标记：每次导航都会重置 —— 登出回到登录页时会重新自动登录。
  var submitted = false;

  // 登录页已显示错误（凭据错/被限流）时不要再提交，避免失败后反复重载形成死循环。
  function loginFailed() {
    var sels = ['.alert-error', '.error-container', '.errors', '.alert-danger',
                '.invalid-feedback', '[role=alert]', '.errorlist', '.form-error',
                '.flash-error', '.message-error'];
    for (var i = 0; i < sels.length; i++) {
      var list;
      try { list = document.querySelectorAll(sels[i]); } catch (e) { continue; }
      for (var j = 0; j < list.length; j++) {
        var el = list[j];
        if (visible(el) && (el.textContent || '').trim().length > 0) return true;
      }
    }
    return false;
  }

  function nativeSet(el, v) {
    try {
      var d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
      d.set.call(el, v);
    } catch (e) { el.value = v; }
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function visible(el) {
    return !!(el && (el.offsetParent !== null || el.getClientRects().length));
  }

  function pick(sels) {
    for (var i = 0; i < sels.length; i++) {
      var list;
      try { list = document.querySelectorAll(sels[i]); } catch (e) { continue; }
      for (var j = 0; j < list.length; j++) if (visible(list[j])) return list[j];
    }
    // 退一步：忽略可见性
    for (var k = 0; k < sels.length; k++) {
      try { var e2 = document.querySelector(sels[k]); } catch (e) { continue; }
      if (e2) return e2;
    }
    return null;
  }

  function submit(form, btn) {
    if (btn && visible(btn)) { btn.click(); return true; }
    if (form) {
      if (form.requestSubmit) { try { form.requestSubmit(); return true; } catch (e) {} }
      form.submit();
      return true;
    }
    return false;
  }

  var tries = 0;
  function attempt() {
    tries++;
    if (submitted) return true;
    if (loginFailed()) return true;

    // 同一页可能有多个同 action 的表单（隐藏模板 + 真实表单），
    // 必须把账号密码填进**同一个可见表单**，否则 POST 会缺字段。
    var u = pick(USER_SEL.split('|'));
    var p = null;
    if (u) {
      var f0 = u.closest('form');
      if (f0) {
        var cands = f0.querySelectorAll('input[type=password]');
        for (var ci = 0; ci < cands.length; ci++) {
          if (visible(cands[ci])) { p = cands[ci]; break; }
        }
        if (!p && cands.length) p = cands[0];
      }
    }
    if (!p) p = pick(PASS_SEL.split('|'));
    // 用户已经自己填了密码（例如登出后手动输入）就不要覆盖
    if (p && p.value && p.value.length > 0) return true;
    if (!u || !p) {
      // 没有登录表单通常意味着已登录（或非登录页），到此为止
      if (tries > 24) return true;
      return false;
    }
    submitted = true;
    nativeSet(u, USER);
    nativeSet(p, PASS);
    setTimeout(function () {
      var btn = pick(SUBMIT_SEL.split('|'));
      var form = u.closest('form') || p.closest('form');
      submit(form, btn);
    }, 250);
    return true;
  }

  if (attempt()) return;
  var n = 0;
  var t = setInterval(function () {
    n++;
    if (attempt() || n > 60) clearInterval(t);
  }, 500);
})();
