package com.acorn.soso.security;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.http.HttpStatus;
import org.springframework.web.server.ResponseStatusException;

/**
 * 업로드 이미지 조회가 업로드 폴더 밖의 파일을 읽지 못하는지 확인한다.
 * 예전 코드는 경로를 그대로 이어 붙여서 "../" 같은 이름으로 다른 파일을 읽을 여지가 있었다.
 */
class UploadImageReaderTest {

	@TempDir
	Path root;

	private Path upload;
	private UploadImageReader reader;

	@BeforeEach
	void setUp() throws Exception {
		upload = Files.createDirectory(root.resolve("upload"));
		Files.writeString(upload.resolve("1774590404767사진 파일.png"), "image", StandardCharsets.UTF_8);
		Files.writeString(root.resolve("secret.txt"), "secret", StandardCharsets.UTF_8);
		Files.createDirectory(upload.resolve("sub"));
		reader = new UploadImageReader(upload.toString());
	}

	@Test
	void readsFileInsideUploadFolderIncludingKoreanName() throws Exception {
		assertThat(new String(reader.read("1774590404767사진 파일.png"), StandardCharsets.UTF_8)).isEqualTo("image");
	}

	@Test
	void rejectsNamesThatLeaveUploadFolder() {
		for (String name : new String[] { "../secret.txt", "..\\secret.txt", "..", ".", "sub/../../secret.txt",
				root.resolve("secret.txt").toString() }) {
			assertNotFound(name);
		}
	}

	@Test
	void rejectsMissingFilesDirectoriesAndBlankNames() {
		assertNotFound("none.png");
		assertNotFound("sub");
		assertNotFound("");
		assertNotFound(null);
		assertNotFound("a\0.png");
	}

	private void assertNotFound(String name) {
		assertThatThrownBy(() -> reader.read(name))
				.as("name=%s", name)
				.isInstanceOfSatisfying(ResponseStatusException.class,
						e -> assertThat(e.getStatusCode()).isEqualTo(HttpStatus.NOT_FOUND));
	}
}
