# MNtfs — Landing page

Trang giới thiệu tĩnh, tông tối theo giao diện app. Hai phiên bản:

| File | Dùng khi |
|---|---|
| **`standalone.html`** | 1 file **tự chứa** — mọi ảnh đã nhúng base64. Gửi/host ở đâu cũng chạy, không cần thư mục `assets/`. |
| **`index.html`** + `assets/` | Bản gốc để chỉnh sửa; ảnh nằm rời trong `assets/` (đã tối ưu, ~656 KB). |

Ảnh screenshot các bước cài đặt: `assets/install.jpg`, `assets/step-1.jpg` … `assets/step-4.jpg`.

## Xem thử / phát hành

- Xem tại chỗ: mở `standalone.html` (hoặc `index.html`) bằng trình duyệt.
- Phát hành: đưa `standalone.html` (đổi tên thành `index.html`) lên GitHub Pages / Netlify / Vercel / server bất kỳ.
- Nút tải trỏ `MNtfs-0.1.0.dmg` — đặt file DMG cạnh trang, hoặc sửa link trỏ tới GitHub Release.

## Dựng lại `standalone.html` sau khi đổi ảnh

Tối ưu ảnh trong `assets/` rồi thay chuỗi `src="assets/…"` trong `index.html`
bằng data-URI base64 tương ứng.
