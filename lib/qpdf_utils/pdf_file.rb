module QPDFUtils
  class PdfFile
    def initialize(pdf_file, options = {})
      validate pdf_file

      @temp_files = []
      @file = pdf_file
      @qpdf_runner = options[:qpdf_runner] || ShellRunner.new(QPDFUtils.qpdf_binary)
      @password = options[:password]
    end

    def file
      if is_encrypted?
        @decrypted_file = create_temp_file
        decrypt(@password, @decrypted_file)
        @decrypted_file
      else
        @file
      end
    end

    def is_encrypted?
      if @is_encrypted.nil?
        @is_encrypted = check_encryption(@file)
      else
        @is_encrypted
      end
    end

    def pages
      @pages ||= count_pages
    end

    def extract_page(page, targetfile)
      extract_page_range(page..page, targetfile)
    end

    def extract_page_range(page_range, targetfile)
      page_from = page_range.first
      page_to = page_range.last
      if page_from < 1 || page_from > page_to || page_to > pages
        raise OutOfBounds, "page range #{page_range} is out of bounds (1..#{pages})", caller
      end
      @qpdf_runner.run %W[--empty --pages #{@file} #{page_from}-#{page_to} -- #{targetfile}]
      raise ProcessingError, 'extracted page is 0 bytes', caller if File.size(targetfile).zero?
      targetfile
    end

    # targetfile_template = "test-%d.pdf"
    def extract_pages(targetfile_template)
      (1..pages).map do |page|
        targetfile = sprintf(targetfile_template, page)
        @qpdf_runner.run %W[--empty --pages #{@file} #{page} -- #{targetfile}]
        targetfile
      end
    end

    def append_files(*pdf_files, targetfile)
      pdf_files.map! do |pdf_file, password|
        validate pdf_file
        if check_encryption pdf_file
          decrypt_file = create_temp_file
          decrypt(password, decrypt_file)
          decrypt_file
        else
          pdf_file
        end
      end
      @qpdf_runner.run %W[--empty --pages #{@file}] + pdf_files + %W[-- #{targetfile}]
      targetfile
    end

    def decrypt(password = nil, targetfile=nil)
      begin
        @qpdf_runner.run %W[--decrypt --password=#{password} #{@file} #{targetfile.nil? ? '--replace-input' : targetfile}]
      rescue CommandFailed
        if $?.exitstatus == 2
          raise InvalidPassword, "failed to decrypt #{@file}, invalid/missing password?", caller
        else
          raise
        end
      end
      if targetfile.nil?
        @file
      else
        targetfile
      end
    end

    def encrypt(user_password, owner_password, key_length, targetfile=nil)
      begin
        @qpdf_runner.run %W[--encrypt #{user_password} #{owner_password} #{key_length} -- #{@file} #{targetfile.nil? ? '--replace-input' : targetfile}]
      rescue CommandFailed
        if $?.exitstatus == 2
          raise ProcessingError, "failed to encrypt #{@file}", caller
        else
          raise
        end
      end
      if targetfile.nil?
        @file
      else
        targetfile
      end
    end

    def cleanup!
      @temp_files.each do |temp_file|
        next if temp_file.nil?
        temp_file.close!
      end
      @temp_files = []
      @decrypted_file = nil
    end

    private

    def create_temp_file
      temp_file = Tempfile.new(%w[temp .pdf])
      temp_file.close
      @temp_files << temp_file
      temp_file.path
    end

    def check_encryption(pdf_file)
      head = 0
      foot = [File.size(pdf_file) - 4096, 0].max
      check_for_encrypt(pdf_file, head, foot)
    end

    def check_for_encrypt(pdf_file, *offsets)
      offsets.each do |offset|
        return true unless IO.binread(pdf_file, 4096, offset).index('/Encrypt').nil?
      end
      false
    end

    def validate(pdf_file)
      raise Errno::ENOENT unless File.exist? pdf_file
      raise BadFileType, "#{pdf_file} does not appear to be a PDF", caller unless QPDFUtils.is_pdf? pdf_file
    end

    def count_pages
      output = @qpdf_runner.run_with_output %W[--show-npages #{@file}]
      num_pages = output.to_i
      raise ProcessingError, 'could not determine number of pages', caller if num_pages.zero?

      num_pages
    end

  end
end
