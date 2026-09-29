# Mixed DPI v10 Checklist

## A. Startup

- [ ] Runtime เปิดโดยไม่มี GDScript parse error
- [ ] เห็น log `virtual desktop` และจำนวน monitor ถูกต้อง
- [ ] เห็น log `active monitor DPI`
- [ ] Companion ปรากฏในตำแหน่งที่บันทึกไว้
- [ ] Tray icon ยังทำงาน

## B. Cross-monitor drag

- [ ] ลากจากจอหลักไปจอซ้ายได้
- [ ] ลากจากจอซ้ายไปจอขวาได้
- [ ] Hover Menu หายทันทีเมื่อเริ่มลาก
- [ ] หลังปล่อย เมนูไม่เด้งกลับจน pointer ออกจากตัวละคร
- [ ] ไม่มี window jump หรือ overlay หลุดตำแหน่ง

## C. Mixed DPI

- [ ] `screen_get_scale()` รายงานค่าต่างกันตาม Windows Display Scale
- [ ] ตัวละครปรับขนาดเมื่อข้าม monitor boundary
- [ ] ขนาดไม่กระโดดซ้ำไปมาขณะอยู่กลางจอเดียวกัน
- [ ] Hitbox ตรงกับตัวละครที่ 100%
- [ ] Hitbox ตรงกับตัวละครที่ 150%
- [ ] Hitbox ตรงกับตัวละครที่ 200%
- [ ] Hover Menu อยู่ข้างตัวละครทุก scale
- [ ] Bubble อยู่เหนือศีรษะทุก scale
- [ ] Click-through ไม่บล็อก desktop นอก input island

## D. Persistence

- [ ] ปล่อยลากแล้ว state มี `companionDesktopPosition`
- [ ] state มี `screenIndex`
- [ ] state มี `screenScale`
- [ ] Restart แล้วกลับ monitor เดิม
- [ ] Hide to tray แล้ว Restore อยู่ตำแหน่งเดิม
- [ ] Quick Panel ไม่เปิดอัตโนมัติหลัง Restore

## E. Monitor topology changes

- [ ] ถอด monitor ที่ Companion อยู่ แล้วตัวละคร snap ไปจอที่เหลือ
- [ ] เสียบ monitor กลับแล้ว overlay refresh
- [ ] เปลี่ยน monitor arrangement แล้ว Companion ไม่หาย
- [ ] ปล่อยในช่องว่างระหว่างจอแล้ว snap กลับจอที่ใกล้ที่สุด
- [ ] รองรับ monitor ที่มี desktop coordinate ติดลบ

## F. Regression

- [ ] Animation Menu สร้างจาก animation ที่มีจริง
- [ ] Change Character Picker เปิดได้
- [ ] Activate character แล้ว reload โดยไม่ restart
- [ ] Test Bubble ทำงาน
- [ ] Quick Panel เปิดด้วย click ไม่เปิดด้วย hover
- [ ] Hover Menu ไม่สั่น
- [ ] Tray Show แสดงเฉพาะ Companion

## Known follow-up: Native per-monitor windows

- [ ] สร้าง Window หนึ่งตัวต่อ monitor
- [ ] แยก DPI context ต่อ Window
- [ ] ย้าย Companion presentation ระหว่าง viewport
- [ ] ย้าย click-through polygon ไป Window ปัจจุบัน
- [ ] กำหนด owner Window ของ Quick Panel และ Character Picker
- [ ] รองรับ monitor hot-plug โดยสร้าง/ลบ Window แบบ dynamic
