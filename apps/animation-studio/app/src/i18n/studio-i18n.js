const STORAGE_KEY = "ocp.animationStudio.locale.v1";

export const STUDIO_LOCALES = ["en", "th"];

const TH = {
  "OCP Animation Studio": "OCP Animation Studio",
  "Character Animation": "แอนิเมชันตัวละคร",
  "Sprite Sheet FX · Beta": "Sprite Sheet FX · เบต้า",
  "Creator Portal ↗": "Creator Portal ↗",
  "Workflow": "เวิร์กโฟลว์",
  "How to use": "วิธีใช้งาน",
  "Project": "โปรเจกต์",
  "Import videos": "นำเข้าวิดีโอ",
  "Timing & frames": "เวลาและเฟรม",
  "Clean & anchor": "ตัดพื้นหลังและจัด Anchor",
  "Sheet composer": "สร้าง Sprite Sheet",
  "Preview & QA": "พรีวิวและ QA",
  "Build .ocp": "สร้าง .ocp",
  "Create a character project.": "สร้างโปรเจกต์ตัวละคร",
  "Import Standard, Optional, or Custom animation videos.": "นำเข้าวิดีโอแอนิเมชันแบบ Standard, Optional หรือ Custom",
  "Set timing, cleanup, and anchor.": "ตั้งเวลา ตัดพื้นหลัง และกำหนด Anchor",
  "Compose sprite sheets and preview Runtime behavior.": "สร้าง sprite sheet และพรีวิวการทำงานใน Runtime",
  "Build the local .ocp package and test it in Runtime.": "สร้างแพ็กเกจ .ocp ภายในเครื่องและทดสอบใน Runtime",
  "Sign in to your OCP Account; this PC provisions its protected signing key.": "เข้าสู่ OCP Account เพื่อให้พีซีนี้สร้างคีย์ลงนามที่ป้องกันไว้",
  "Sign + Upload + Validate in Creator Cloud.": "ลงนาม + อัปโหลด + ตรวจสอบใน Creator Cloud",
  "Open Creator Portal and submit for C8 review.": "เปิด Creator Portal และส่งเข้า C8 review",
  "After approval, verify the release in OCP Store and Desktop Runtime.": "หลังอนุมัติ ให้ตรวจ release ใน OCP Store และ Desktop Runtime",
  "Electron Desktop Studio": "Electron Desktop Studio",
  "Browser Preview": "พรีวิวบนเบราว์เซอร์",
  "Source MP4 stays local": "ไฟล์ MP4 ต้นฉบับอยู่ในเครื่องเท่านั้น",
  "Back": "ย้อนกลับ",
  "Next step": "ขั้นตอนถัดไป",
  "Finish": "เสร็จสิ้น",
  "Animation ready": "แอนิเมชันพร้อมแล้ว",
  "Animation load progress": "ความคืบหน้าการโหลดแอนิเมชัน",
  "Studio language": "ภาษาของ Studio",
  "Character Project": "โปรเจกต์ตัวละคร",
  "Local-first": "ทำงานในเครื่องเป็นหลัก",
  "New Character": "สร้างตัวละครใหม่",
  "Save Project": "บันทึกโปรเจกต์",
  "Export Project": "ส่งออกโปรเจกต์",
  "Open Project": "เปิดโปรเจกต์",
  "Character package": "แพ็กเกจตัวละคร",
  "Package ID": "Package ID",
  "Package version": "เวอร์ชันแพ็กเกจ",
  "Display name": "ชื่อที่แสดง",
  "Description (English)": "รายละเอียดตัวละคร (อังกฤษ)",
  "Description (Thai)": "รายละเอียดตัวละคร (ไทย)",
  "Author / Publisher": "ผู้สร้าง / Publisher",
  "License": "สัญญาอนุญาต",
  "Entry schema": "Entry schema",
  "Entry schema (latest)": "Entry schema (ล่าสุด)",
  "TTS voice presentation": "ลักษณะเสียง TTS",
  "TTS age": "ช่วงอายุเสียง TTS",
  "Thai speech style": "รูปแบบการพูดภาษาไทย",
  "MARKETPLACE IDENTITY": "MARKETPLACE IDENTITY",
  "Package ID availability & ownership": "สถานะ Package ID และความเป็นเจ้าของ",
  "Local format": "รูปแบบภายในเครื่อง",
  "Creator authority": "สิทธิ์ Creator",
  "Marketplace": "Marketplace",
  "Use character.<slug>": "ใช้รูปแบบ character.<slug>",
  "Sign in + complete creator setup": "เข้าสู่ระบบและตั้งค่า Creator ให้เสร็จ",
  "Available — reserve before first publish": "พร้อมใช้งาน — จองก่อนเผยแพร่ครั้งแรก",
  "Reserved by your creator account": "จองโดย Creator account ของคุณแล้ว",
  "Published identity owned by your publisher": "Publisher ของคุณเป็นเจ้าของ identity ที่เผยแพร่แล้ว",
  "Owned submission found — renew reservation before another upload": "พบ submission ของคุณ — ต่ออายุการจองก่อนอัปโหลดครั้งถัดไป",
  "Not checked against Marketplace yet": "ยังไม่ได้ตรวจสอบกับ Marketplace",
  "Check Marketplace": "ตรวจ Marketplace",
  "Checking…": "กำลังตรวจ…",
  "Reserving…": "กำลังจอง…",
  "Renew 72h reservation": "ต่ออายุการจอง 72 ชม.",
  "Reserve for 72 hours": "จองไว้ 72 ชม.",
  "Release reservation": "ยกเลิกการจอง",
  "Releasing…": "กำลังยกเลิก…",
  "Local validation does not guarantee Marketplace availability. Creator Cloud is authoritative, and publish re-checks this identity immediately before build/upload.": "การตรวจในเครื่องไม่ได้รับประกันว่า Marketplace จะยังว่างอยู่ Creator Cloud เป็นแหล่งข้อมูลหลัก และระบบจะตรวจ identity ซ้ำก่อน build/upload ทุกครั้ง",
  "Build optimization": "การปรับแต่ง Build",
  "Sprite package format": "รูปแบบไฟล์ Sprite",
  "WebP — Recommended": "WebP — แนะนำ",
  "PNG — Lossless": "PNG — ไม่สูญเสียข้อมูล",
  "WebP quality": "คุณภาพ WebP",
  "SFX package format": "รูปแบบไฟล์ SFX",
  "OGG Vorbis — Recommended": "OGG Vorbis — แนะนำ",
  "WAV — Lossless": "WAV — ไม่สูญเสียข้อมูล",
  "Vorbis quality": "คุณภาพ Vorbis",
  "Archive compression": "การบีบอัด Archive",
  "DEFLATE — Recommended": "DEFLATE — แนะนำ",
  "Store only": "ไม่บีบอัด",
  "Package budget": "ขนาดแพ็กเกจเป้าหมาย",
  "Import MP4 files": "นำเข้าไฟล์ MP4",
  "Import folder": "นำเข้าโฟลเดอร์",
  "Standard sources": "ต้นฉบับ Standard",
  "Standard sheets": "ชีต Standard",
  "optional/custom source / sheet": "ต้นฉบับ / ชีต optional-custom",
  "Local": "ภายในเครื่อง",
  "browser processing": "ประมวลผลบนเบราว์เซอร์",
  "Canvas profile": "โปรไฟล์ Canvas",
  "Frame width": "ความกว้างเฟรม",
  "Frame height": "ความสูงเฟรม",
  "Feet anchor X": "Feet anchor X",
  "Feet anchor Y": "Feet anchor Y",
  "Sheet grids": "กริดของชีต",
  "Playback FPS": "FPS การเล่น",
  "Animation sources": "ต้นฉบับแอนิเมชัน",
  "Add videos": "เพิ่มวิดีโอ",
  "Standard 22 animations remain the compatibility set. Directional/interaction and custom animations are optional.": "แอนิเมชัน Standard 22 รายการยังเป็นชุด compatibility ส่วน directional/interaction และ custom เป็นตัวเลือกเพิ่มเติม",
  "Custom animation": "แอนิเมชัน Custom",
  "+ Add Custom Animation": "+ เพิ่ม Custom Animation",
  "Built-in optional slots: Climb Top, directional Climb Up/Down Left/Right, Hang Left/Right, Drag Hold, and Drag Release. Use directional climb slots for text, logos, or asymmetric artwork that must never be mirrored. Custom names become generic package actions automatically and do not require a Runtime code change.": "สล็อตเสริมที่มีให้: Climb Top, Climb Up/Down แบบแยกซ้าย/ขวา, Hang Left/Right, Drag Hold และ Drag Release หากภาพมีตัวหนังสือ โลโก้ หรือรายละเอียดซ้ายขวาไม่เหมือนกัน ให้ใช้สล็อต Climb แบบแยกทิศทางเพื่อไม่ให้ภาพถูกกลับด้าน ส่วนชื่อ Custom จะถูกสร้างเป็น package action อัตโนมัติโดยไม่ต้องแก้ Runtime",
  "Standard": "Standard",
  "Optional": "Optional",
  "Custom": "Custom",
  "Not imported": "ยังไม่ได้นำเข้า",
  "Source video audio": "เสียงจากวิดีโอต้นฉบับ",
  "External file missing": "ไม่พบไฟล์ภายนอก",
  "No sound": "ไม่มีเสียง",
  "Change video": "เปลี่ยนวิดีโอ",
  "Add video": "เพิ่มวิดีโอ",
  "Remove": "ลบ",
  "Animation SFX": "Animation SFX",
  "Add WAV / OGG": "เพิ่ม WAV / OGG",
  "Import SFX folder": "นำเข้าโฟลเดอร์ SFX",
  "Apply recommended SFX defaults": "ใช้ค่า SFX ที่แนะนำ",
  "Bulk SFX uses the same filename mapping as video import, including custom animation names already added to this project.": "การนำเข้า SFX แบบกลุ่มใช้การจับคู่ชื่อไฟล์แบบเดียวกับวิดีโอ รวมถึงชื่อ custom animation ที่เพิ่มในโปรเจกต์แล้ว",
  "SFX is optional and never required for every animation": "SFX เป็นตัวเลือก ไม่จำเป็นต้องมีทุกแอนิเมชัน",
  "Optional/custom clips are packaged only when authored": "คลิป Optional/Custom จะถูกแพ็กเฉพาะเมื่อมีการสร้างไว้",
  "Standard 22 remain the release compatibility requirement": "Standard 22 ยังเป็นข้อกำหนด compatibility สำหรับ release",
  "Output profile": "โปรไฟล์ Output",
  "Animation": "แอนิเมชัน",
  "Start time": "เวลาเริ่ม",
  "End time": "เวลาสิ้นสุด",
  "Target FPS": "FPS เป้าหมาย",
  "Target frames": "จำนวนเฟรมเป้าหมาย",
  "Loop animation": "เล่นแอนิเมชันวนซ้ำ",
  "Custom Action": "Custom Action",
  "Priority": "ลำดับความสำคัญ",
  "Ambient": "Ambient",
  "Presentation": "Presentation",
  "Reaction": "Reaction",
  "Lifecycle": "Lifecycle",
  "Cooldown": "Cooldown",
  "Allow other presentation actions to interrupt (Physics always wins)": "อนุญาตให้ presentation action อื่นแทรกได้ (Physics มีลำดับสูงสุดเสมอ)",
  "Sample selected": "สุ่มเฟรมรายการที่เลือก",
  "Sample all imported": "สุ่มเฟรมทั้งหมดที่นำเข้า",
  "Demo frames (test)": "เฟรมตัวอย่าง (ทดสอบ)",
  "Candidate timeline + SFX": "Timeline ตัวอย่าง + SFX",
  "Source": "ต้นฉบับ",
  "Output": "ผลลัพธ์",
  "Target": "เป้าหมาย",
  "Loop": "วนซ้ำ",
  "SFX source": "แหล่ง SFX",
  "Use source video audio": "ใช้เสียงจากวิดีโอต้นฉบับ",
  "External WAV / OGG": "WAV / OGG ภายนอก",
  "SFX gain": "ระดับเสียง SFX",
  "Fade in": "Fade in",
  "Fade out": "Fade out",
  "Loop SFX while animation is active": "เล่น SFX วนซ้ำขณะแอนิเมชันทำงาน",
  "Attach WAV / OGG": "แนบ WAV / OGG",
  "Original source": "ต้นฉบับ",
  "Cleanup preset": "Preset การตัดพื้นหลัง",
  "Normal character": "ตัวละครปกติ",
  "FX / Glow": "FX / Glow",
  "Cleanup strength": "ความแรง Cleanup",
  "Key color": "สี Key",
  "Picked from video": "เลือกจากวิดีโอ",
  "Auto detect": "ตรวจจับอัตโนมัติ",
  "Pick from video": "เลือกสีจากวิดีโอ",
  "Pick background now": "คลิกเลือกสีพื้นหลัง",
  "Sampled color cut": "ตัดตามสีที่เลือก",
  "Green screen cut": "ตัด Green Screen",
  "Green screen cut sensitivity": "ความไวการตัด Green Screen",
  "Green screen cut sensitivity value": "ค่าความไวการตัด Green Screen",
  "Background cut": "ตัดพื้นหลัง",
  "Background cut sensitivity": "ความไวการตัดพื้นหลัง",
  "Background cut sensitivity value": "ค่าความไวการตัดพื้นหลัง",
  "Advanced green screen tuning": "ปรับ Green Screen ขั้นสูง",
  "Advanced auto matte tuning": "ปรับ Auto Matte ขั้นสูง",
  "Advanced sampled key tuning": "ปรับสี Key ที่เลือกขั้นสูง",
  "Foreground protect": "ป้องกัน Foreground",
  "Key color tolerance": "ความคลาดเคลื่อนของ Key color",
  "Dark shadow cut": "ตัดเงามืด",
  "Enclosed green cut": "ตัดสีเขียวในช่องปิด",
  "Enclosed key cut": "ตัดสี Key ในช่องปิด",
  "Matte contract": "หดขอบ Matte",
  "Edge feather": "ทำขอบนุ่ม",
  "De-spill": "ลดสีเขียวสะท้อน",
  "Scale": "สเกล",
  "Character scale": "สเกลตัวละคร",
  "Offset X": "Offset X",
  "Offset Y": "Offset Y",
  "Character horizontal offset": "ระยะเลื่อนตัวละครแนวนอน",
  "Character vertical offset": "ระยะเลื่อนตัวละครแนวตั้ง",
  "Apply Cleanup V7 Sampled Key": "ใช้ Cleanup V7 Sampled Key",
  "Apply Cleanup V7 Sampled Key to all": "ใช้ Cleanup V7 Sampled Key กับทั้งหมด",
  "Auto-align feet": "จัดแนวเท้าอัตโนมัติ",
  "Cleanup QA": "Cleanup QA",
  "Updating live source preview…": "กำลังอัปเดตพรีวิวต้นฉบับ…",
  "Live source preview · Apply to bake all frames": "พรีวิวต้นฉบับแบบสด · กด Apply เพื่อประมวลผลทุกเฟรม",
  "Live preview failed · showing last applied frame": "พรีวิวสดล้มเหลว · แสดงเฟรมล่าสุดที่ใช้สำเร็จ",
  "Inspect edge matte before compose": "ตรวจขอบ matte ก่อนสร้างชีต",
  "Spill detector": "ตรวจสีเขียวตกค้าง",
  "Alpha mask": "Alpha mask",
  "Checker": "ตารางหมากรุก",
  "Black": "ดำ",
  "White": "ขาว",
  "Gray": "เทา",
  "Frame": "เฟรม",
  "QA zoom": "ซูม QA",
  "Mode": "โหมด",
  "Zoom": "ซูม",
  "Compose sheets": "สร้างชีต",
  "Frame sizes match": "ขนาดเฟรมตรงกัน",
  "Row-major indexing": "ลำดับเฟรมแบบ row-major",
  "PNG transparency": "PNG โปร่งใส",
  "Compose selected": "สร้างชีตรายการที่เลือก",
  "Compose all sampled": "สร้างชีตทุกแอนิเมชันที่สุ่มเฟรมแล้ว",
  "Runtime preview": "พรีวิว Runtime",
  "Export Store preview (public)": "ส่งออก Store preview (public)",
  "Exporting…": "กำลังส่งออก…",
  "Separate low-resolution public images. No private package or audio. Review before publishing.": "สร้างรูป public ความละเอียดต่ำแยกต่างหาก ไม่มีแพ็กเกจส่วนตัวหรือเสียง กรุณาตรวจก่อนเผยแพร่",
  "Pause": "หยุดชั่วคราว",
  "Play": "เล่น",
  "Animation + Sound": "แอนิเมชัน + เสียง",
  "Loop on": "เปิดวนซ้ำ",
  "Loop off": "ปิดวนซ้ำ",
  "Duration": "ระยะเวลา",
  "None": "ไม่มี",
  "External audio not attached": "ยังไม่ได้แนบเสียงภายนอก",
  "Quality report": "รายงานคุณภาพ",
  "No preview": "ไม่มีพรีวิว",
  "No sampled frame": "ยังไม่มีเฟรมตัวอย่าง",
  "Animation frame preview": "พรีวิวเฟรมแอนิเมชัน",
  "Package summary": "สรุปแพ็กเกจ",
  "Build + Save .ocp": "Build + บันทึก .ocp",
  "Building + saving .ocp…": "กำลัง Build + บันทึก .ocp…",
  "Exporting .ocp…": "กำลังส่งออก .ocp…",
  "Export .ocp draft": "ส่งออก .ocp draft",
  "Open build in Explorer": "เปิด Build ใน Explorer",
  "Sending to Runtime…": "กำลังส่งไป Runtime…",
  "Install build to Runtime Test": "ติดตั้ง Build ไปยัง Runtime Test",
  "OCP Desktop workspace": "OCP Desktop workspace",
  "Choose a workspace when saving": "เลือก workspace ตอนบันทึก",
  "build ready": "Build พร้อม",
  "no saved build": "ยังไม่มี Build ที่บันทึก",
  "connected": "เชื่อมต่อแล้ว",
  "offline": "ออฟไลน์",
  "ready": "พร้อม",
  "not provisioned": "ยังไม่ได้ตั้งค่า",
  "Creator Cloud · C6 → C8": "Creator Cloud · C6 → C8",
  "Private quarantine · validation · Security Gate · auto submit for review": "Private quarantine · validation · Security Gate · ส่ง review อัตโนมัติ",
  "Creator Cloud not configured. Cloud account settings are shown globally in the top bar.": "ยังไม่ได้ตั้งค่า Creator Cloud การตั้งค่าบัญชี Cloud อยู่ที่แถบด้านบน",
  "OCP Account is managed globally in the top bar. Sign in and complete creator setup there before uploading.": "OCP Account จัดการจากแถบด้านบน กรุณาเข้าสู่ระบบและตั้งค่า Creator ให้เสร็จก่อนอัปโหลด",
  "Marketplace identity": "Marketplace identity",
  "Build + local sign": "Build + ลงนามในเครื่อง",
  "Create private submission": "สร้าง private submission",
  "Upload to R2 quarantine": "อัปโหลดไป R2 quarantine",
  "Finalize upload": "ยืนยันการอัปโหลด",
  "Cloud validation": "ตรวจสอบบน Cloud",
  "Security Gate": "Security Gate",
  "Submit for C8 review": "ส่งเข้า C8 review",
  "Creator Cloud working...": "Creator Cloud กำลังทำงาน...",
  "Waiting for moderator": "รอ Moderator",
  "Retry Cloud validation": "ลอง Cloud validation อีกครั้ง",
  "Retry Submit for Review": "ลองส่ง Review อีกครั้ง",
  "Retry Upload + Validate": "ลองอัปโหลด + ตรวจสอบอีกครั้ง",
  "Upload + Validate + Submit for Review": "อัปโหลด + ตรวจสอบ + ส่ง Review",
  "Open Creator Portal": "เปิด Creator Portal",
  "character.json preview": "พรีวิว character.json",
  "OCP Desktop": "OCP Desktop",
  "No workspace selected": "ยังไม่ได้เลือก workspace",
  "Workspace": "Workspace",
  "No local folder selected": "ยังไม่ได้เลือกโฟลเดอร์ Local",
  "Local folder": "โฟลเดอร์ Local",
  "Choosing…": "กำลังเลือก…",
  "OCP Account": "OCP Account",
  "Cloud not configured": "ยังไม่ได้ตั้งค่า Cloud",
  "Not signed in": "ยังไม่ได้เข้าสู่ระบบ",
  "Authenticated": "ยืนยันตัวตนแล้ว",
  "Creator setup required": "ต้องตั้งค่า Creator",
  "Continue with Google": "ดำเนินการต่อด้วย Google",
  "Google sign-in…": "กำลังเข้าสู่ระบบ Google…",
  "Continue with Microsoft": "ดำเนินการต่อด้วย Microsoft",
  "Microsoft sign-in…": "กำลังเข้าสู่ระบบ Microsoft…",
  "Email sign in": "เข้าสู่ระบบด้วยอีเมล",
  "Link this PC": "เชื่อมพีซีเครื่องนี้",
  "Linking…": "กำลังเชื่อม…",
  "Sign out": "ออกจากระบบ",
  "Creator setup failed": "ตั้งค่า Creator ไม่สำเร็จ",
  "Could not create this Creator publisher.": "ไม่สามารถสร้าง Creator publisher นี้ได้",
  "Local mode · Sign in to publish": "โหมด Local · เข้าสู่ระบบเมื่อจะเผยแพร่",
  "Create Creator publisher": "สร้าง Creator publisher",
  "Add Creator publisher": "เพิ่ม Creator publisher",
  "+ Publisher": "+ Publisher",
  "Cancel Publisher": "ยกเลิกการเพิ่ม Publisher",
  "Add Publisher": "เพิ่ม Publisher",
  "Reserved Publisher": "Publisher ที่สงวนไว้",
  "creator.ocp is reserved for the verified OCP Official account.": "creator.ocp สงวนไว้สำหรับบัญชี OCP Official ที่ผ่านการยืนยันแล้ว",
  "Add another Publisher to this OCP Account. Each Publisher keeps its own protected signing identity.": "เพิ่ม Publisher อีกตัวให้ OCP Account นี้ โดยแต่ละ Publisher มี signing identity ที่ป้องกันแยกจากกัน",
  "Choose a public creator.<public-id> after signing in. This is a Marketplace Publisher ID, not your login name or email.": "หลังเข้าสู่ระบบ ให้เลือก Publisher ID สาธารณะในรูปแบบ creator.<public-id> โดยค่านี้ไม่ใช่ชื่อ Login หรืออีเมลของคุณ",
  "Create a public Publisher identity for Cloud/Marketplace publishing. Local character authoring stays available without a Publisher.": "สร้าง Publisher สำหรับเผยแพร่ขึ้น Cloud/Marketplace โดยการสร้างและแก้ตัวละครแบบ Local ยังใช้งานได้แม้ไม่มี Publisher",
  "Local project · sign in to assign Publisher": "โปรเจกต์ Local · เข้าสู่ระบบเพื่อกำหนด Publisher",
  "Local / Unverified · ocp.local": "Local / ยังไม่ยืนยัน · ocp.local",
  "Choose this public Publisher ID once. Your private signing key stays protected on this PC.": "เลือก Publisher ID สาธารณะนี้ครั้งเดียว ส่วน private signing key จะยังคงป้องกันอยู่ในพีซีเครื่องนี้",
  "Creator display name": "ชื่อ Creator ที่แสดง",
  "Setting up…": "กำลังตั้งค่า…",
  "Create Creator workspace": "สร้าง Creator workspace",
  "OCP Desktop Creator sign in": "เข้าสู่ Creator ผ่าน OCP Desktop",
  "Creator email sign in": "เข้าสู่ Creator ด้วยอีเมล",
  "Use the same OCP Account email credentials.": "ใช้ข้อมูลอีเมลของ OCP Account เดียวกัน",
  "Password": "รหัสผ่าน",
  "Signing in…": "กำลังเข้าสู่ระบบ…",
  "Sign in": "เข้าสู่ระบบ",
  "Sprite Sheet FX Pack Composer": "ตัวสร้าง Sprite Sheet FX Pack",
  "Three independent videos, three runtime slots, one signed Effect Pack.": "วิดีโออิสระ 3 รายการ, Runtime slot 3 ช่อง, รวมเป็น Effect Pack ที่ลงนามแล้ว 1 ชุด",
  "Beta · Admin": "เบต้า · Admin",
  "converted": "แปลงแล้ว",
  "3 videos recommended": "แนะนำวิดีโอ 3 รายการ",
  "Generate white/neutral FX": "สร้าง FX สีขาว/กลาง",
  "Runtime tint can then recolor cleanly by Bond Rank": "Runtime จะสามารถเปลี่ยนสีตาม Bond Rank ได้สะอาด",
  "Bond Rank Colors": "สี Bond Rank",
  "Runtime tint": "Runtime tint",
  "Static": "คงที่",
  "Use base tint": "ใช้สีพื้นฐาน",
  "Bond Rank": "Bond Rank",
  "Cyan → Blue → Purple → Gold": "Cyan → Blue → Purple → Gold",
  "Pack Identity": "ข้อมูลแพ็ก",
  "Name": "ชื่อ",
  "Version": "เวอร์ชัน",
  "Build Pack": "สร้าง Pack",
  "Waiting": "กำลังรอ",
  "Export PNG Sheets": "ส่งออก PNG Sheets",
  "Export effect.json": "ส่งออก effect.json",
  "Building…": "กำลัง Build…",
  "Build signed .ocp": "สร้าง .ocp ที่ลงนามแล้ว",
  "Publish to Creator Cloud": "เผยแพร่ไป Creator Cloud",
  "Generated Contract": "Contract ที่สร้างแล้ว",
  "Read-only": "อ่านอย่างเดียว",
  "Choose source video": "เลือกวิดีโอต้นฉบับ",
  "reading metadata": "กำลังอ่าน metadata",
  "Runtime budget": "งบหน่วยความจำ Runtime",
  "Excellent": "ยอดเยี่ยม",
  "Good": "ดี",
  "Heavy": "หนัก",
  "Too heavy": "หนักเกินไป",
  "Runtime cap": "ขีดจำกัด Runtime",
  "Character": "ตัวละคร",
  "ON": "เปิด",
  "OFF": "ปิด",
};

const TEMPLATES = [
  [/^Step (\d+) of (\d+)$/, (_m, current, total) => `ขั้นตอน ${current} จาก ${total}`],
  [/^(\d+) sheets ready$/, (_m, count) => `พร้อมแล้ว ${count} ชีต`],
  [/^(\d+)\/(\d+) imported$/, (_m, current, total) => `นำเข้าแล้ว ${current}/${total}`],
  [/^(\d+)\/(\d+) configured$/, (_m, current, total) => `ตั้งค่าแล้ว ${current}/${total}`],
  [/^(\d+)\/(\d+) ready$/, (_m, current, total) => `พร้อม ${current}/${total}`],
  [/^(\d+) slot\(s\)$/, (_m, count) => `${count} สล็อต`],
  [/^Reservation expires (.+) · reserve again to renew another 72 hours\.$/, (_m, when) => `การจองหมดอายุ ${when} · จองซ้ำเพื่อต่ออายุอีก 72 ชั่วโมง`],
  [/^Workspace · (.+)$/, (_m, name) => `Workspace · ${name}`],
  [/^Cloud · (.+)$/, (_m, rest) => `Cloud · ${rest}`],
];

function preserveOuterWhitespace(source, translated) {
  const leading = source.match(/^\s*/)?.[0] ?? "";
  const trailing = source.match(/\s*$/)?.[0] ?? "";
  return leading + translated + trailing;
}

export function normalizeStudioLocale(value) {
  return String(value || "").toLowerCase().startsWith("th") ? "th" : "en";
}

export function readStudioLocale() {
  try {
    const saved = window.localStorage.getItem(STORAGE_KEY);
    if (saved) return normalizeStudioLocale(saved);
  } catch {
    // Local storage can be unavailable in hardened previews.
  }
  return normalizeStudioLocale(typeof navigator !== "undefined" ? navigator.language : "en");
}

export function persistStudioLocale(locale) {
  const normalized = normalizeStudioLocale(locale);
  try { window.localStorage.setItem(STORAGE_KEY, normalized); } catch { /* no-op */ }
  if (typeof document !== "undefined") {
    document.documentElement.lang = normalized;
    document.documentElement.dataset.studioLocale = normalized;
  }
  return normalized;
}

export function translateStudioText(value, locale) {
  const source = String(value ?? "");
  if (normalizeStudioLocale(locale) !== "th" || !source.trim()) return source;
  const trimmed = source.trim();
  const direct = TH[trimmed];
  if (direct) return preserveOuterWhitespace(source, direct);
  for (const [pattern, replace] of TEMPLATES) {
    const match = trimmed.match(pattern);
    if (match) return preserveOuterWhitespace(source, replace(...match));
  }
  return source;
}

const textSources = new WeakMap();
const attributeSources = new WeakMap();
const TRANSLATABLE_ATTRIBUTES = ["placeholder", "title", "aria-label"];
const SKIP_SELECTOR = "pre, code, script, style, textarea, .studio-json, .effect-json-preview";

function shouldSkip(node) {
  const parent = node.nodeType === 1 ? node : node.parentElement;
  return Boolean(parent?.closest?.(SKIP_SELECTOR));
}

function localizeTextNode(node, locale) {
  if (!node?.nodeValue || shouldSkip(node)) return;
  const current = node.nodeValue;
  let source = textSources.get(node);
  if (source == null) {
    source = current;
    textSources.set(node, source);
  } else {
    const translated = translateStudioText(source, "th");
    if (current !== source && current !== translated) {
      source = current;
      textSources.set(node, source);
    }
  }
  const target = translateStudioText(source, locale);
  if (target !== current) node.nodeValue = target;
}

function localizeAttributes(element, locale) {
  if (!element?.getAttribute || shouldSkip(element)) return;
  let sources = attributeSources.get(element);
  if (!sources) {
    sources = new Map();
    attributeSources.set(element, sources);
  }
  for (const attribute of TRANSLATABLE_ATTRIBUTES) {
    if (!element.hasAttribute(attribute)) continue;
    const current = element.getAttribute(attribute) ?? "";
    let source = sources.get(attribute);
    if (source == null) {
      source = current;
      sources.set(attribute, source);
    } else {
      const translated = translateStudioText(source, "th");
      if (current !== source && current !== translated) {
        source = current;
        sources.set(attribute, source);
      }
    }
    const target = translateStudioText(source, locale);
    if (target !== current) element.setAttribute(attribute, target);
  }
}

function localizeSubtree(root, locale) {
  if (!root || typeof document === "undefined") return;
  if (root.nodeType === 3) {
    localizeTextNode(root, locale);
    return;
  }
  if (root.nodeType === 1) localizeAttributes(root, locale);
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
  let node = walker.nextNode();
  while (node) {
    if (node.nodeType === 3) localizeTextNode(node, locale);
    else localizeAttributes(node, locale);
    node = walker.nextNode();
  }
}

export function installStudioDomLocalization(root, locale) {
  if (!root || typeof MutationObserver === "undefined") return () => undefined;
  const normalized = persistStudioLocale(locale);
  localizeSubtree(root, normalized);
  const observer = new MutationObserver((records) => {
    for (const record of records) {
      if (record.type === "characterData") localizeTextNode(record.target, normalized);
      if (record.type === "attributes") localizeAttributes(record.target, normalized);
      for (const node of record.addedNodes || []) localizeSubtree(node, normalized);
    }
  });
  observer.observe(root, {
    subtree: true,
    childList: true,
    characterData: true,
    attributes: true,
    attributeFilter: TRANSLATABLE_ATTRIBUTES,
  });
  return () => observer.disconnect();
}
