-- Create private storage bucket for memo attachments (US-014)
-- Private: no public access. Web/Apple clients authenticate every transfer;
-- Drizzle migration 0029 later narrows upload to exact reservations and removes
-- authenticated deletion.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'memo-attachments',
  'memo-attachments',
  false,
  52428800, -- 50 MB
  ARRAY[
    'audio/m4a',
    'audio/mp4',
    'image/jpeg',
    'image/png',
    'image/heic',
    'image/heif',
    'application/pdf'
  ]
)
ON CONFLICT (id) DO NOTHING;

-- Initial RLS, retained here for migration history. 0029 replaces the write
-- policies with the verified v2 contract.
-- Storage path format after 0029: {user_id}/{memo_id}/{sha256}.{ext}

CREATE POLICY "memo_attachments_insert"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'memo-attachments'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

CREATE POLICY "memo_attachments_select"
ON storage.objects FOR SELECT
TO authenticated
USING (
  bucket_id = 'memo-attachments'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

CREATE POLICY "memo_attachments_delete"
ON storage.objects FOR DELETE
TO authenticated
USING (
  bucket_id = 'memo-attachments'
  AND (storage.foldername(name))[1] = auth.uid()::text
);
