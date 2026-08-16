(() => {
  const target = document.getElementById("invite-qr");
  if (target && window.QRCode) {
    new QRCode(target, window.location.href);
  }
})();
