package com.acorn.soso.security;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.InvalidPathException;
import java.nio.file.Path;
import java.nio.file.Paths;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ResponseStatusException;

/**
 * 업로드 이미지 조회(/users/images, /group/images, /editor/images)의 공통 읽기.
 * 요청한 이름을 업로드 폴더 기준으로 풀어서, 폴더 밖을 가리키거나 없는 파일이면 404로 끝낸다.
 * 저장 이름에 원래 파일명(한글 포함)이 들어가므로 문자 종류는 제한하지 않고 경로만 검사한다.
 */
@Component
public class UploadImageReader {

	private final Path baseDir;

	public UploadImageReader(@Value("${file.location}") String fileLocation) {
		this.baseDir = Paths.get(fileLocation).toAbsolutePath().normalize();
	}

	public byte[] read(String imageName) throws IOException {
		if (imageName == null || imageName.isEmpty()
				|| imageName.indexOf('/') >= 0 || imageName.indexOf('\\') >= 0 || imageName.indexOf('\0') >= 0
				|| imageName.equals(".") || imageName.equals("..")) {
			throw notFound();
		}
		Path target;
		try {
			target = baseDir.resolve(imageName).normalize();
		} catch (InvalidPathException e) {
			throw notFound();
		}
		if (!target.startsWith(baseDir) || !Files.isRegularFile(target)) {
			throw notFound();
		}
		return Files.readAllBytes(target);
	}

	private static ResponseStatusException notFound() {
		return new ResponseStatusException(HttpStatus.NOT_FOUND);
	}
}
