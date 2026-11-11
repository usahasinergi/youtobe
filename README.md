# KubangYT

Dark dashboard untuk mengelola metadata akun YouTube, channel yang dihubungkan melalui OAuth resmi, aktivitas, draft komentar, dan empat slot URL browser.

## Stack
- Static frontend (Cloudflare Pages compatible)
- Supabase Auth + Postgres + Row Level Security
- YouTube Data API via OAuth 2.0 (integrasi lanjutan)

## Keamanan
- Jangan menyimpan password Google, cookie browser, private key, atau refresh token di frontend/repository.
- Gunakan OAuth resmi dan simpan token sensitif hanya di backend/secret store.
- Semua tabel publik mengaktifkan RLS dan membatasi data berdasarkan auth.uid().
- Fitur tidak mengotomatisasi subscribe/like/comment untuk menaikkan engagement secara artifisial.

## Deploy
Cloudflare Pages: hubungkan repository ini, framework preset None, build command kosong, output directory `/`.
